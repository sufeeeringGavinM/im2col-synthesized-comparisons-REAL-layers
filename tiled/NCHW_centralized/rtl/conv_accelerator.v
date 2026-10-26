// Full-layer scheduler and serialized SRAM-like memory transfers.
// Backing memory is external to this module: one-cycle enabled reads, edge writes.
// Each external word holds one operand in its low bits or one ACC_WIDTH result.
`timescale 1ns/1ps
module conv_accelerator #(
    parameter ARRAY_SIZE=10, BIT_WIDTH=8, ACC_WIDTH=32,
    parameter INPUT_ADDR_WIDTH=8, OUTPUT_ADDR_WIDTH=8, KERNEL_ADDR_WIDTH=8,
    parameter CFG_WIDTH=32, MEM_ADDR_WIDTH=32,
    parameter MEM_DATA_WIDTH=(ACC_WIDTH>BIT_WIDTH ? ACC_WIDTH : BIT_WIDTH)
) (
    input clk, nrst, start,
    output busy, output reg done,
    input [CFG_WIDTH-1:0] cfg_N,cfg_C,cfg_H,cfg_W,cfg_K,cfg_R,cfg_S,cfg_P,cfg_Q,
    input [CFG_WIDTH-1:0] cfg_pad_i,cfg_pad_j,cfg_stride_i,cfg_stride_j,cfg_dilation_i,cfg_dilation_j,
    input [MEM_ADDR_WIDTH-1:0] cfg_input_base,cfg_kernel_base,cfg_output_base,
    output reg mem_re, mem_we,
    output reg [MEM_ADDR_WIDTH-1:0] mem_raddr,mem_waddr,
    input [MEM_DATA_WIDTH-1:0] mem_rdata,
    output reg [MEM_DATA_WIDTH-1:0] mem_wdata
);
  localparam INPUT_DEPTH=2**INPUT_ADDR_WIDTH, OUTPUT_DEPTH=2**OUTPUT_ADDR_WIDTH,
             KERNEL_DEPTH=2**KERNEL_ADDR_WIDTH;
  localparam IDLE=0, SETUP=1, PLAN_TILE=2, PREPARE=3,
             INPUT_READ=4, INPUT_WRITE=5, KERNEL_READ=6, KERNEL_WRITE=7,
             START_CORE=8, WAIT_CORE=9, OUTPUT_READ=10, OUTPUT_WRITE=11, NEXT_TILE=12;
  reg [3:0] state;
  reg [CFG_WIDTH-1:0] N,C,H,W,K,R,S,P,Q,pad_i,pad_j,stride_i,stride_j,dilation_i,dilation_j;
  reg [MEM_ADDR_WIDTH-1:0] input_base,kernel_base,output_base;
  reg [CFG_WIDTH-1:0] n0,k0,p0,q0,c0,tap_r,tap_s;
  reg [CFG_WIDTH-1:0] tile_k,tile_q,tile_c,c_step,q_limit;
  reg tap_mode;
  reg [CFG_WIDTH-1:0] patch_h,patch_w,patch_i,patch_j,local_pad_i,local_pad_j;
  reg [CFG_WIDTH-1:0] bank_index,word_index;
  wire [CFG_WIDTH-1:0] local_R=tap_mode?1:R, local_S=tap_mode?1:S;
  wire [CFG_WIDTH-1:0] patch_words=patch_h*patch_w;
  wire [CFG_WIDTH-1:0] kernel_words=tile_c*local_R*local_S;
  wire core_busy,core_done;
  wire [ARRAY_SIZE-1:0][ACC_WIDTH-1:0] stored_output;
  reg [ARRAY_SIZE-1:0] input_we,kernel_we;
  reg [ARRAY_SIZE-1:0][INPUT_ADDR_WIDTH-1:0] input_addr;
  reg [ARRAY_SIZE-1:0][KERNEL_ADDR_WIDTH-1:0] kernel_addr;
  reg [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] input_data,kernel_data;

  reg [63:0] input_channel_pitch,kernel_filter_pitch,kernel_channel_pitch,output_filter_pitch;
  reg [63:0] input_dma_addr,input_row_base,input_channel_base;
  reg [63:0] kernel_dma_addr,kernel_filter_base,output_dma_addr,output_filter_base;
  reg [CFG_WIDTH-1:0] dma_column,dma_row;
  reg signed [63:0] output_row_origin,output_col_origin,tap_i_offset,tap_j_offset;
  assign busy=state!=IDLE;

  // Bound the actual channel-last swizzled storage, including tile holes.
  // Reserve enough groups for Ct channels and enough spatial slots for the
  // complete requested patch; clipping can only reduce this bound.
  localparam JOB_SETUP=14;
  reg [4:0] job_step;
  reg job_pending;
  reg [63:0] extent_i,extent_j,taps;
  reg needs_taps;
  reg [63:0] plan_c,plan_q,plan_temp;
  reg [63:0] spatial_rows,min_cols,spatial_footprint,input_channels,kernel_channels,bounded_c,groups;
  wire job_div_done;
  wire [63:0] job_quotient,job_remainder;
  reg [63:0] job_numerator,job_denominator;
  reg job_division;
  always @* begin
    job_numerator=0;job_denominator=1;job_division=0;
    case(job_step)
      0:begin job_division=1;job_numerator=extent_i+R-1;job_denominator=R;end
      1:begin job_division=1;job_numerator=extent_j+S-1;job_denominator=S;end
      4:begin job_division=1;job_numerator=needs_taps ? 64'(KERNEL_DEPTH) : 64'(INPUT_DEPTH);job_denominator=needs_taps ? 64'(1) : spatial_footprint;end
      5:begin job_division=1;job_numerator=needs_taps ? 64'(KERNEL_DEPTH) : plan_temp*ARRAY_SIZE;job_denominator=needs_taps ? 64'(1) : taps;end
      6:begin job_division=1;job_numerator=KERNEL_DEPTH;job_denominator=needs_taps ? 64'(1) : taps;end
      10:begin job_division=1;job_numerator=INPUT_DEPTH;job_denominator=needs_taps ? 64'(1) : groups*spatial_rows;end
      11:begin job_division=1;job_numerator=needs_taps ? 64'(INPUT_DEPTH-1) : plan_temp*S-extent_j;job_denominator=stride_j;end
    endcase
  end
  setup_divider #(.WIDTH(64)) u_job_setup (
    .clk(clk),.clear(!nrst || state!=JOB_SETUP),.start(state==JOB_SETUP && job_division && !job_pending),
    .numerator(job_numerator),.denominator(job_denominator),.done(job_div_done),.quotient(job_quotient),.remainder(job_remainder));

  // DMA iterates logical local channels/pixels, then places each sample once
  // in exactly the bank/address used by im2col_addr_gen (local N=1).
  wire [63:0] local_h=dma_row,local_w=dma_column;
  reg [63:0] tile_rows,tile_cols,spatial_pitch;
  reg [CFG_WIDTH-1:0] local_hr,local_wr,local_wq;
  reg [63:0] row_word_base;
  localparam BW=(ARRAY_SIZE>1?$clog2(ARRAY_SIZE):1);
  localparam ADDRESS_SETUP=13;
  reg [2:0] address_setup_step;
  reg address_pending;
  wire address_div_done;
  wire [63:0] address_quotient,address_remainder;
  wire [63:0] address_numerator=address_setup_step==0 ? 64'(patch_h)+local_R-1 : 64'(patch_w)+local_S-1;
  setup_divider #(.WIDTH(64)) u_dma_setup (
    .clk(clk),.clear(!nrst || state!=ADDRESS_SETUP),
    .start(state==ADDRESS_SETUP && address_setup_step<2 && !address_pending),
    .numerator(address_numerator),.denominator(address_setup_step==0 ? 64'(local_R) : 64'(local_S)),
    .done(address_div_done),.quotient(address_quotient),.remainder(address_remainder));
  reg [BW-1:0] input_bank,row_bank,channel_bank;
  reg signed [63:0] group_address,row_group_address,channel_group_address;
  reg [BW-1:0] delta_bank[0:4];
  reg signed [63:0] delta_address[0:4];
  wire signed [63:0] slot_delta[0:4];
  assign slot_delta[0]=1;
  assign slot_delta[1]=1-$signed(64'(local_S));
  assign slot_delta[2]=$signed(64'(local_S));
  assign slot_delta[3]=(1-$signed(64'(local_R)))*$signed(64'(local_S));
  assign slot_delta[4]=$signed(64'(local_R))*$signed(64'(local_S));
  function automatic signed [63:0] floor_banks(input signed [63:0] value);
    begin floor_banks=value/ARRAY_SIZE; if(value<0 && value%ARRAY_SIZE!=0) floor_banks=floor_banks-1; end
  endfunction
  function automatic [BW-1:0] hop_bank(input [BW-1:0] b,d);
    reg [BW:0] sum;begin sum={1'b0,b}+{1'b0,d};hop_bank=BW'(sum>=ARRAY_SIZE ? sum-ARRAY_SIZE : sum);end
  endfunction
  function automatic signed [63:0] hop_address(input signed [63:0] a,input [BW-1:0] b,d,input signed [63:0] increment);
    reg [BW:0] sum;begin sum={1'b0,b}+{1'b0,d};hop_address=a+increment+(sum>=ARRAY_SIZE ? spatial_pitch : 0);end
  endfunction
  wire [2:0] col_move=local_wr==local_S-1 ? 1 : 0;
  wire [2:0] row_move=local_hr==local_R-1 ? 3 : 2;
  wire [63:0] input_word=group_address+row_word_base+local_wq;
  integer delta_index;

  // Clip a real input rectangle to the image. Local padding is the distance
  // from the requested origin to its clipped origin. No padded pixels are DMA'd.
  wire signed [63:0] raw_i=output_row_origin+tap_i_offset;
  wire signed [63:0] raw_j=output_col_origin+tap_j_offset;
  wire signed [63:0] end_i=raw_i+$signed(tap_mode?64'd1:extent_i);
  wire signed [63:0] end_j=raw_j+$signed(64'(tile_q-1)*stride_j)+(tap_mode?64'sd1:$signed(extent_j));
  wire signed [63:0] clip_i=raw_i<0?0:raw_i, clip_j=raw_j<0?0:raw_j;
  wire signed [63:0] stop_i=end_i>$signed(64'(H))?$signed(64'(H)):end_i;
  wire signed [63:0] stop_j=end_j>$signed(64'(W))?$signed(64'(W)):end_j;
  wire [63:0] clipped_h=stop_i>clip_i?stop_i-clip_i:0;
  wire [63:0] clipped_w=stop_j>clip_j?stop_j-clip_j:0;

  // Memory read data is consumed in the following WRITE state, never on the
  // edge that issues its read. Local output reads follow the same rule.
  always @* begin
    mem_re=0;mem_we=0;mem_raddr=0;mem_waddr=0;mem_wdata=0;
    input_we=0;kernel_we=0;input_addr=0;kernel_addr=0;input_data=0;kernel_data=0;
    if(nrst) begin
    case(state)
      INPUT_READ: begin
        mem_re=1;
        mem_raddr=MEM_ADDR_WIDTH'(input_dma_addr);
      end
      INPUT_WRITE: begin
        input_we[input_bank]=1;
        input_addr[input_bank]=INPUT_ADDR_WIDTH'(input_word);
        input_data[input_bank]=mem_rdata[BIT_WIDTH-1:0];
      end
      KERNEL_READ: begin
        mem_re=1;
        mem_raddr=MEM_ADDR_WIDTH'(kernel_dma_addr);
      end
      KERNEL_WRITE: begin
        kernel_we[bank_index]=1;
        kernel_addr[bank_index]=KERNEL_ADDR_WIDTH'(word_index);
        kernel_data[bank_index]=mem_rdata[BIT_WIDTH-1:0];
      end
      OUTPUT_WRITE: begin
        mem_we=1;
        mem_waddr=MEM_ADDR_WIDTH'(output_dma_addr);
        mem_wdata=MEM_DATA_WIDTH'(stored_output[bank_index]);
      end
    endcase
    end
  end

  conv_core #(.ARRAY_SIZE(ARRAY_SIZE),.BIT_WIDTH(BIT_WIDTH),.ACC_WIDTH(ACC_WIDTH),
    .INPUT_ADDR_WIDTH(INPUT_ADDR_WIDTH),.OUTPUT_ADDR_WIDTH(OUTPUT_ADDR_WIDTH),
    .KERNEL_ADDR_WIDTH(KERNEL_ADDR_WIDTH),.CFG_WIDTH(CFG_WIDTH)) u_core (
    .clk(clk),.nrst(nrst),.start(state==START_CORE),.busy(core_busy),.done(core_done),
    .cfg_continue_sum(c0!=0 || tap_r!=0 || tap_s!=0),
    .cfg_N(CFG_WIDTH'(1)),.cfg_C(tile_c),.cfg_H(patch_h),.cfg_W(patch_w),
    .cfg_K(tile_k),.cfg_R(local_R),.cfg_S(local_S),.cfg_P(CFG_WIDTH'(1)),.cfg_Q(tile_q),
    .cfg_pad_i(local_pad_i),.cfg_pad_j(local_pad_j),
    .cfg_stride_i(stride_i),.cfg_stride_j(stride_j),
    .cfg_dilation_i(dilation_i),.cfg_dilation_j(dilation_j),
    .sram_we_ext(input_we),.sram_waddr_ext(input_addr),.sram_wdata_ext(input_data),
    .kernel_we_ext(kernel_we),.kernel_waddr_ext(kernel_addr),.kernel_wdata_ext(kernel_data),
    .output_read_enable(state==OUTPUT_READ),.output_read_addr(OUTPUT_ADDR_WIDTH'(word_index)),
    .output_read_data(stored_output),.acc_col_out()
  );

  always @(posedge clk) begin
    if(!nrst) begin
      input_channel_pitch<=0;kernel_filter_pitch<=0;kernel_channel_pitch<=0;output_filter_pitch<=0;
      input_dma_addr<=0;input_row_base<=0;input_channel_base<=0;kernel_dma_addr<=0;kernel_filter_base<=0;output_dma_addr<=0;output_filter_base<=0;
      dma_column<=0;dma_row<=0;output_row_origin<=0;output_col_origin<=0;tap_i_offset<=0;tap_j_offset<=0;
      tile_rows<=0;tile_cols<=0;spatial_pitch<=0;local_hr<=0;local_wr<=0;local_wq<=0;row_word_base<=0;
      input_bank<=0;row_bank<=0;channel_bank<=0;group_address<=0;row_group_address<=0;channel_group_address<=0;
      address_setup_step<=0;address_pending<=0;
      for(delta_index=0;delta_index<5;delta_index=delta_index+1) begin delta_bank[delta_index]<=0;delta_address[delta_index]<=0;end
      job_step<=0;job_pending<=0;extent_i<=0;extent_j<=0;taps<=0;needs_taps<=0;plan_c<=0;plan_q<=0;plan_temp<=0;
      spatial_rows<=0;min_cols<=0;spatial_footprint<=0;input_channels<=0;kernel_channels<=0;bounded_c<=0;groups<=0;
      state<=IDLE;done<=0;
      N<=1;C<=1;H<=1;W<=1;K<=1;R<=1;S<=1;P<=1;Q<=1;
      pad_i<=0;pad_j<=0;stride_i<=1;stride_j<=1;dilation_i<=1;dilation_j<=1;
      input_base<=0;kernel_base<=0;output_base<=0;
      n0<=0;k0<=0;p0<=0;q0<=0;c0<=0;tap_r<=0;tap_s<=0;
      tile_k<=0;tile_q<=0;tile_c<=0;c_step<=1;q_limit<=1;tap_mode<=0;
      patch_h<=0;patch_w<=0;patch_i<=0;patch_j<=0;local_pad_i<=0;local_pad_j<=0;
      bank_index<=0;word_index<=0;
    end else begin
      done<=0;
      case(state)
        IDLE: if(start) begin
          N<=cfg_N;C<=cfg_C;H<=cfg_H;W<=cfg_W;K<=cfg_K;R<=cfg_R;S<=cfg_S;P<=cfg_P;Q<=cfg_Q;
          pad_i<=cfg_pad_i;pad_j<=cfg_pad_j;stride_i<=cfg_stride_i;stride_j<=cfg_stride_j;
          dilation_i<=cfg_dilation_i;dilation_j<=cfg_dilation_j;
          output_row_origin<=-$signed(64'(cfg_pad_i));output_col_origin<=-$signed(64'(cfg_pad_j));
          input_base<=cfg_input_base;kernel_base<=cfg_kernel_base;output_base<=cfg_output_base;
          n0<=0;k0<=0;p0<=0;q0<=0;state<=SETUP;
        end
        SETUP: begin
          input_channel_pitch<=64'(H)*W;
          kernel_channel_pitch<=64'(R)*S;
          kernel_filter_pitch<=64'(C)*R*S;
          output_filter_pitch<=64'(P)*Q;
          extent_i<=64'(dilation_i)*(R-1)+1;extent_j<=64'(dilation_j)*(S-1)+1;taps<=64'(R)*S;
          job_step<=0;job_pending<=0;state<=JOB_SETUP;
        end
        JOB_SETUP: begin
          case(job_step)
            0:begin
              if(!job_pending) job_pending<=1;
              if(job_div_done) begin spatial_rows<=job_quotient; job_pending<=0;job_step<=1;end
            end
            1:begin
              if(!job_pending) job_pending<=1;
              if(job_div_done) begin min_cols<=job_quotient; job_pending<=0;job_step<=2;end
            end
            2:begin spatial_footprint<=spatial_rows*min_cols; job_step<=3;end
            3:begin needs_taps<=(taps>KERNEL_DEPTH || ((taps+ARRAY_SIZE-1)/ARRAY_SIZE)*spatial_footprint>INPUT_DEPTH); job_step<=4;end
            4:begin
              if(!job_pending) job_pending<=1;
              if(job_div_done) begin plan_temp<=job_quotient; job_pending<=0;job_step<=5;end
            end
            5:begin
              if(!job_pending) job_pending<=1;
              if(job_div_done) begin input_channels<=job_quotient; job_pending<=0;job_step<=6;end
            end
            6:begin
              if(!job_pending) job_pending<=1;
              if(job_div_done) begin kernel_channels<=job_quotient; job_pending<=0;job_step<=7;end
            end
            7:begin plan_c<=input_channels<kernel_channels ? input_channels : kernel_channels; job_step<=8;end
            8:begin bounded_c<=plan_c<ARRAY_SIZE ? plan_c : ARRAY_SIZE; job_step<=9;end
            9:begin groups<=(bounded_c*taps+ARRAY_SIZE-1)/ARRAY_SIZE; job_step<=10;end
            10:begin
              if(!job_pending) job_pending<=1;
              if(job_div_done) begin plan_temp<=job_quotient; job_pending<=0;job_step<=11;end
            end
            11:begin
              if(!job_pending) job_pending<=1;
              if(job_div_done) begin plan_q<=job_quotient+1; job_pending<=0;job_step<=12;end
            end
            default:begin
              tap_mode<=needs_taps;
              c_step<=CFG_WIDTH'(plan_c<ARRAY_SIZE?plan_c:ARRAY_SIZE);
              q_limit<=CFG_WIDTH'(plan_q<OUTPUT_DEPTH?plan_q:OUTPUT_DEPTH);
              state<=PLAN_TILE;
            end
          endcase
        end
        PLAN_TILE: begin
          tap_i_offset<=0;tap_j_offset<=0;
          output_dma_addr<=64'(output_base)+((64'(n0)*K+k0)*P+p0)*Q+q0;
          output_filter_base<=64'(output_base)+((64'(n0)*K+k0)*P+p0)*Q+q0;
          tile_q<=Q-q0<q_limit?Q-q0:q_limit;
          tile_k<=K-k0<ARRAY_SIZE?K-k0:CFG_WIDTH'(ARRAY_SIZE);
          c0<=0;tap_r<=0;tap_s<=0;state<=PREPARE;
        end
        PREPARE: begin
          dma_column<=0;dma_row<=0;
          input_dma_addr<=64'(input_base)+(64'(n0)*C+c0)*input_channel_pitch+64'(clip_i)*W+64'(clip_j);
          input_row_base<=64'(input_base)+(64'(n0)*C+c0)*input_channel_pitch+64'(clip_i)*W+64'(clip_j);
          input_channel_base<=64'(input_base)+(64'(n0)*C+c0)*input_channel_pitch+64'(clip_i)*W+64'(clip_j);
          kernel_dma_addr<=64'(kernel_base)+64'(k0)*kernel_filter_pitch+64'(c0)*kernel_channel_pitch+(tap_mode ? 64'(tap_r)*S+tap_s : 0);
          kernel_filter_base<=64'(kernel_base)+64'(k0)*kernel_filter_pitch+64'(c0)*kernel_channel_pitch+(tap_mode ? 64'(tap_r)*S+tap_s : 0);
          local_hr<=0;local_wr<=0;local_wq<=0;row_word_base<=0;
          input_bank<=0;row_bank<=0;channel_bank<=0;group_address<=0;row_group_address<=0;channel_group_address<=0;
          address_setup_step<=0;address_pending<=0;
          tile_c<=C-c0<c_step?C-c0:c_step;
          patch_h<=CFG_WIDTH'(clipped_h);patch_w<=CFG_WIDTH'(clipped_w);
          patch_i<=CFG_WIDTH'(clip_i);patch_j<=CFG_WIDTH'(clip_j);
          local_pad_i<=CFG_WIDTH'(clip_i-raw_i);local_pad_j<=CFG_WIDTH'(clip_j-raw_j);
          bank_index<=0;word_index<=0;
          state<=(clipped_h!=0 && clipped_w!=0)?ADDRESS_SETUP:KERNEL_READ;
        end
        ADDRESS_SETUP: begin
          if(address_setup_step<2) begin
            if(!address_pending) address_pending<=1;
            if(address_div_done) begin
              address_pending<=0;address_setup_step<=address_setup_step+1'b1;
              if(address_setup_step==0) tile_rows<=address_quotient;else tile_cols<=address_quotient;
            end
          end else if(address_setup_step==2) begin spatial_pitch<=tile_rows*tile_cols;address_setup_step<=3;end
          else if(address_setup_step==3) begin
            for(delta_index=0;delta_index<5;delta_index=delta_index+1) begin
              delta_bank[delta_index]<=BW'(slot_delta[delta_index]-floor_banks(slot_delta[delta_index])*ARRAY_SIZE);
              delta_address[delta_index]<=floor_banks(slot_delta[delta_index])*$signed(spatial_pitch);
            end
            address_setup_step<=4;
          end else state<=INPUT_READ;
        end
        INPUT_READ: state<=INPUT_WRITE;
        INPUT_WRITE: begin
          if(word_index+1<patch_words) begin
            if(dma_column+1<patch_w) begin dma_column<=dma_column+1'b1;input_dma_addr<=input_dma_addr+1;end
            else begin dma_column<=0;dma_row<=dma_row+1'b1;input_row_base<=input_row_base+W;input_dma_addr<=input_row_base+W;end
          end else begin
            dma_column<=0;dma_row<=0;
            input_channel_base<=input_channel_base+input_channel_pitch;
            input_row_base<=input_channel_base+input_channel_pitch;input_dma_addr<=input_channel_base+input_channel_pitch;
          end
          if(word_index+1==patch_words) begin
            input_bank<=hop_bank(channel_bank,delta_bank[4]);row_bank<=hop_bank(channel_bank,delta_bank[4]);channel_bank<=hop_bank(channel_bank,delta_bank[4]);
            group_address<=hop_address(channel_group_address,channel_bank,delta_bank[4],delta_address[4]);row_group_address<=hop_address(channel_group_address,channel_bank,delta_bank[4],delta_address[4]);channel_group_address<=hop_address(channel_group_address,channel_bank,delta_bank[4],delta_address[4]);
            local_hr<=0;local_wr<=0;local_wq<=0;row_word_base<=0;
          end else if(dma_column+1==patch_w) begin
            input_bank<=hop_bank(row_bank,delta_bank[row_move]);row_bank<=hop_bank(row_bank,delta_bank[row_move]);
            group_address<=hop_address(row_group_address,row_bank,delta_bank[row_move],delta_address[row_move]);row_group_address<=hop_address(row_group_address,row_bank,delta_bank[row_move],delta_address[row_move]);
            local_hr<=local_hr==local_R-1 ? 0 : local_hr+1'b1;local_wr<=0;local_wq<=0;
            if(local_hr==local_R-1) row_word_base<=row_word_base+tile_cols;
          end else begin
            input_bank<=hop_bank(input_bank,delta_bank[col_move]);group_address<=hop_address(group_address,input_bank,delta_bank[col_move],delta_address[col_move]);
            local_wr<=local_wr==local_S-1 ? 0 : local_wr+1'b1;
            if(local_wr==local_S-1) local_wq<=local_wq+1'b1;
          end
          state<=INPUT_READ;
          if(word_index+1<patch_words) word_index<=word_index+1'b1;
          else begin
            word_index<=0;
            if(bank_index+1<tile_c) bank_index<=bank_index+1'b1;
            else begin bank_index<=0;state<=KERNEL_READ;end
          end
        end
        KERNEL_READ: state<=KERNEL_WRITE;
        KERNEL_WRITE: begin
          if(word_index+1==kernel_words) begin kernel_filter_base<=kernel_filter_base+kernel_filter_pitch;kernel_dma_addr<=kernel_filter_base+kernel_filter_pitch;end
          else kernel_dma_addr<=kernel_dma_addr+(tap_mode ? kernel_channel_pitch : 1);
          state<=KERNEL_READ;
          if(word_index+1<kernel_words) word_index<=word_index+1'b1;
          else begin
            word_index<=0;
            if(bank_index+1<tile_k) bank_index<=bank_index+1'b1;
            else begin bank_index<=0;state<=START_CORE;end
          end
        end
        START_CORE: state<=WAIT_CORE;
        WAIT_CORE: if(core_done) begin
          if(tap_mode && tap_s+1<S) begin tap_s<=tap_s+1'b1;tap_j_offset<=tap_j_offset+$signed(64'(dilation_j));state<=PREPARE;end
          else if(tap_mode && tap_r+1<R) begin tap_s<=0;tap_r<=tap_r+1'b1;tap_j_offset<=0;tap_i_offset<=tap_i_offset+$signed(64'(dilation_i));state<=PREPARE;end
          else if(c0+tile_c<C) begin
            c0<=c0+tile_c;tap_r<=0;tap_s<=0;tap_i_offset<=0;tap_j_offset<=0;state<=PREPARE;
          end else begin bank_index<=0;word_index<=0;state<=OUTPUT_READ;end
        end
        OUTPUT_READ: state<=OUTPUT_WRITE;
        OUTPUT_WRITE: begin
          if(word_index+1==tile_q) begin output_filter_base<=output_filter_base+output_filter_pitch;output_dma_addr<=output_filter_base+output_filter_pitch;end
          else output_dma_addr<=output_dma_addr+1;
          state<=OUTPUT_READ;
          if(word_index+1<tile_q) word_index<=word_index+1'b1;
          else begin
            word_index<=0;
            if(bank_index+1<tile_k) bank_index<=bank_index+1'b1;
            else state<=NEXT_TILE;
          end
        end
        NEXT_TILE: begin
          state<=PLAN_TILE;
          if(q0+tile_q<Q) begin q0<=q0+tile_q;output_col_origin<=output_col_origin+$signed(64'(tile_q)*stride_j);end
          else begin
            q0<=0;output_col_origin<=-$signed(64'(pad_j));
            if(p0+1<P) begin p0<=p0+1'b1;output_row_origin<=output_row_origin+$signed(64'(stride_i));end
            else begin
              p0<=0;output_row_origin<=-$signed(64'(pad_i));
              if(k0+tile_k<K) k0<=k0+tile_k;
              else begin
                k0<=0;
                if(n0+1<N) n0<=n0+1'b1;
                else begin state<=IDLE;done<=1;end
              end
            end
          end
        end
        default: state<=IDLE;
      endcase
    end
  end
endmodule
