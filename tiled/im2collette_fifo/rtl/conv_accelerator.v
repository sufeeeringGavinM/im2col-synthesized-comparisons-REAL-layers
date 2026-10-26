// Full-layer scheduler and serialized SRAM-like memory transfers.
// Backing memory is external to this module: one-cycle enabled reads, edge writes.
// Each external word holds one operand in its low bits or one ACC_WIDTH result.
`timescale 1ns/1ps
// FULL LAYER: select a tile, load its operands, run a local core, store outputs.
// N,C,H,W describe the full input; K,R,S describe filters; P,Q describe output.
// Lowercase n0/k0/p0/q0/c0 are the current tile's first indices, not dimensions.
// _i means height (pad_h/stride_h/dil_h); _j means width (pad_w/stride_w/dil_w).
// External words use NCHW inputs, KCRS weights and NKPQ outputs. Local storage
// is implementation-specific. One local job computes N=P=1, with partial sums
// retained across reduction jobs. READ and WRITE states serialize transfers.
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
  // Captured descriptor registers: stable throughout a job, even if cfg_* ports change.
  reg [CFG_WIDTH-1:0] N,C,H,W,K,R,S,P,Q,pad_i,pad_j,stride_i,stride_j,dilation_i,dilation_j;
  reg [MEM_ADDR_WIDTH-1:0] input_base,kernel_base,output_base;
  reg [CFG_WIDTH-1:0] n0,k0,p0,q0,c0,tap_r,tap_s;
  // tile_k = filters in the current tile; tile_q = adjacent output columns;
  // tile_c = input channels reduced by this local job.
  // c_step/q_limit are setup-calculated capacities, clipped to remaining C/Q.
  // The traversal is for(n) for(k tile) for(p) for(q tile) for(c tile).
  reg [CFG_WIDTH-1:0] tile_k,tile_q,tile_c,c_step,q_limit;
  reg tap_mode;
  reg [CFG_WIDTH-1:0] patch_h,patch_w,patch_i,patch_j,local_pad_i,local_pad_j;
  reg [CFG_WIDTH-1:0] bank_index,word_index;
  // Full-kernel mode uses R,S. Oversized-kernel fallback uses one tap per job
  // (local_R=local_S=1), retaining output sums across tap/channel jobs.
  wire [CFG_WIDTH-1:0] local_R=tap_mode?1:R, local_S=tap_mode?1:S;
  wire [CFG_WIDTH-1:0] patch_words=patch_h*patch_w;
  wire [CFG_WIDTH-1:0] kernel_words=tile_c*local_R*local_S;
  wire core_busy,core_done;
  wire [ARRAY_SIZE-1:0][ACC_WIDTH-1:0] stored_output;
  reg [ARRAY_SIZE-1:0] input_we,kernel_we;
  reg [ARRAY_SIZE-1:0][INPUT_ADDR_WIDTH-1:0] input_addr;
  reg [ARRAY_SIZE-1:0][KERNEL_ADDR_WIDTH-1:0] kernel_addr;
  reg [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] kernel_data;
  reg [ARRAY_SIZE-1:0][8*BIT_WIDTH-1:0] input_data;
  // One packed-word assembly register collects serialized input bytes. It is
  // not another tile buffer. Existing external read/write cycles are unchanged.
  reg [8*BIT_WIDTH-1:0] packed_input;
  reg [8*BIT_WIDTH-1:0] next_packed_input;
  always @* begin next_packed_input=packed_input; next_packed_input[(word_index%8)*BIT_WIDTH +: BIT_WIDTH]=mem_rdata[BIT_WIDTH-1:0]; end

  // "Pitch" = address distance in external MEMORY WORDS, not bytes.
  // input_channel_pitch=H*W; kernel_channel_pitch=R*S;
  // kernel_filter_pitch=C*R*S; output_filter_pitch=P*Q.
  // *_dma_addr is a running transfer address. *_row_base/*_channel_base/
  // *_filter_base save the parent-loop origin to restore after an inner wrap.
  reg [63:0] input_channel_pitch,kernel_filter_pitch,kernel_channel_pitch,output_filter_pitch;
  reg [63:0] input_dma_addr,input_row_base,input_channel_base;
  reg [63:0] kernel_dma_addr,kernel_filter_base,output_dma_addr,output_filter_base;
  reg [CFG_WIDTH-1:0] dma_column,dma_row;
  // Requested input origin = output origin + fallback-tap offset.
  // output_row_origin=p0*stride_h-pad_h; output_col_origin=q0*stride_w-pad_w.
  // These are incremented counters, not recomputed spatial products per access.
  reg signed [63:0] output_row_origin,output_col_origin,tap_i_offset,tap_j_offset;
  assign busy=state!=IDLE;

  // Conservative full-kernel footprint selects a row width that always fits.
  // A single-tap fallback handles kernels or dilated footprints too large even
  // for one output. It keeps the original im2col address generator in use.
  localparam JOB_SETUP=14;
  // Sequential capacity planning: one iterative divider is reused across steps.
  // job_pending means a divide was launched and has not returned its result.
  // extent_i=dil_h*(R-1)+1; extent_j=dil_w*(S-1)+1; taps=R*S.
  reg [4:0] job_step;
  reg job_pending;
  reg [63:0] extent_i,extent_j,taps;
  reg needs_taps;
  // Normal mode: c_step=min(ARRAY_SIZE, floor(KERNEL_DEPTH/(R*S))).
  // A tile needs extent_i*((tile_q-1)*stride_w+extent_j) input words/channel.
  // Thus q_limit=min(OUTPUT_DEPTH,
  //   1+floor((floor(INPUT_DEPTH/extent_i)-extent_j)/stride_w)).
  // Fallback uses one-tap extents when a full footprint cannot fit.
  reg [63:0] plan_c,plan_q,plan_temp;
  // NCHW planner temporaries: spatial_rows/min_cols count coarse R/S blocks;
  // spatial_footprint is their product; input_channels/kernel_channels are fit
  // bounds, not the descriptor C. bounded_c is the selected maximum C chunk;
  // groups counts its ARRAY_SIZE-wide CRS groups. Other wrappers retain these
  // declarations but do not use this swizzled-storage planning path.
  reg [63:0] spatial_rows,min_cols,spatial_footprint,input_channels,kernel_channels,bounded_c,groups;
  wire job_div_done;
  wire [63:0] job_quotient,job_remainder;
  reg [63:0] job_numerator,job_denominator;
  reg job_division;
  always @* begin
    job_numerator=0;job_denominator=1;job_division=0;
    case(job_step)
      1:begin job_division=1;job_numerator=KERNEL_DEPTH;job_denominator=needs_taps ? 64'(1) : taps;end
      2:begin job_division=1;job_numerator=INPUT_DEPTH;job_denominator=needs_taps ? 64'(1) : extent_i;end
      3:begin job_division=1;job_numerator=needs_taps ? 64'(INPUT_DEPTH-1) : plan_temp-extent_j;job_denominator=stride_j;end
    endcase
  end
  setup_divider #(.WIDTH(64)) u_job_setup (
    .clk(clk),.clear(!nrst || state!=JOB_SETUP),.start(state==JOB_SETUP && job_division && !job_pending),
    .numerator(job_numerator),.denominator(job_denominator),.done(job_div_done),.quotient(job_quotient),.remainder(job_remainder));

  // Clip a real input rectangle to the image. Local padding is the distance
  // from the requested origin to its clipped origin. No padded pixels are DMA'd.
  // Requested input rectangle may extend beyond the image. Clip its real pixels
  // to [0,H) x [0,W); local padding reconstructs the missing zeros in the core.
  // end_i/end_j are exclusive bounds. Never DMA synthetic padding values.
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
        input_we[bank_index]=(word_index%8==7 || word_index+1==patch_words);
        // The input SRAM stores BUS_WORDS packed values per word; low index bits
        // select the byte being assembled, high bits select its packed-word address.
        input_addr[bank_index]=INPUT_ADDR_WIDTH'(word_index/8);
        input_data[bank_index]=next_packed_input;
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
    .ADDR_WIDTH(INPUT_ADDR_WIDTH),
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
      job_step<=0;job_pending<=0;extent_i<=0;extent_j<=0;taps<=0;needs_taps<=0;plan_c<=0;plan_q<=0;plan_temp<=0;
      spatial_rows<=0;min_cols<=0;spatial_footprint<=0;input_channels<=0;kernel_channels<=0;bounded_c<=0;groups<=0;
      state<=IDLE;done<=0;
      packed_input<=0;
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
        // Accept one full-layer descriptor only while idle. Initialize outer
        // tile counters and padded origins; subsequent cfg_* changes are ignored.
        IDLE: if(start) begin
          N<=cfg_N;C<=cfg_C;H<=cfg_H;W<=cfg_W;K<=cfg_K;R<=cfg_R;S<=cfg_S;P<=cfg_P;Q<=cfg_Q;
          pad_i<=cfg_pad_i;pad_j<=cfg_pad_j;stride_i<=cfg_stride_i;stride_j<=cfg_stride_j;
          dilation_i<=cfg_dilation_i;dilation_j<=cfg_dilation_j;
          output_row_origin<=-$signed(64'(cfg_pad_i));output_col_origin<=-$signed(64'(cfg_pad_j));
          input_base<=cfg_input_base;kernel_base<=cfg_kernel_base;output_base<=cfg_output_base;
          n0<=0;k0<=0;p0<=0;q0<=0;state<=SETUP;
        end
        // Capture shared pitches/extents. Products are evaluated here once
        // per layer rather than recomputed for each transferred operand.
        SETUP: begin
          input_channel_pitch<=64'(H)*W;
          kernel_channel_pitch<=64'(R)*S;
          kernel_filter_pitch<=64'(C)*R*S;
          output_filter_pitch<=64'(P)*Q;
          extent_i<=64'(dilation_i)*(R-1)+1;extent_j<=64'(dilation_j)*(S-1)+1;taps<=64'(R)*S;
          job_step<=0;job_pending<=0;state<=JOB_SETUP;
        end
        // Run the capacity divisions sequentially, then keep c_step/q_limit
        // unchanged throughout this layer. Setup cycles are part of latency.
        JOB_SETUP: begin
          case(job_step)
            0:begin needs_taps<=(taps>KERNEL_DEPTH || extent_i*extent_j>INPUT_DEPTH); job_step<=1;end
            1:begin
              if(!job_pending) job_pending<=1;
              if(job_div_done) begin plan_c<=job_quotient; job_pending<=0;job_step<=2;end
            end
            2:begin
              if(!job_pending) job_pending<=1;
              if(job_div_done) begin plan_temp<=job_quotient; job_pending<=0;job_step<=3;end
            end
            3:begin
              if(!job_pending) job_pending<=1;
              if(job_div_done) begin plan_q<=job_quotient+1; job_pending<=0;job_step<=4;end
            end
            default:begin
              tap_mode<=needs_taps;
              c_step<=CFG_WIDTH'(plan_c<ARRAY_SIZE?plan_c:ARRAY_SIZE);
              q_limit<=CFG_WIDTH'(plan_q<OUTPUT_DEPTH?plan_q:OUTPUT_DEPTH);
              state<=PLAN_TILE;
            end
          endcase
        end
        // Select the remaining Q columns and K filters that fit this output tile.
        // Compute its first external output address once; stores then increment it.
        PLAN_TILE: begin
          tap_i_offset<=0;tap_j_offset<=0;
          output_dma_addr<=64'(output_base)+((64'(n0)*K+k0)*P+p0)*Q+q0;
          output_filter_base<=64'(output_base)+((64'(n0)*K+k0)*P+p0)*Q+q0;
          tile_q<=Q-q0<q_limit?Q-q0:q_limit;
          tile_k<=K-k0<ARRAY_SIZE?K-k0:CFG_WIDTH'(ARRAY_SIZE);
          c0<=0;tap_r<=0;tap_s<=0;state<=PREPARE;
        end
        // Select the next C reduction chunk and clipped input patch. Set first
        // input/weight DMA addresses from global tile origins and saved pitches.
        // No output is exported until all reduction jobs for this tile finish.
        PREPARE: begin
          dma_column<=0;dma_row<=0;
          input_dma_addr<=64'(input_base)+(64'(n0)*C+c0)*input_channel_pitch+64'(clip_i)*W+64'(clip_j);
          input_row_base<=64'(input_base)+(64'(n0)*C+c0)*input_channel_pitch+64'(clip_i)*W+64'(clip_j);
          input_channel_base<=64'(input_base)+(64'(n0)*C+c0)*input_channel_pitch+64'(clip_i)*W+64'(clip_j);
          kernel_dma_addr<=64'(kernel_base)+64'(k0)*kernel_filter_pitch+64'(c0)*kernel_channel_pitch+(tap_mode ? 64'(tap_r)*S+tap_s : 0);
          kernel_filter_base<=64'(kernel_base)+64'(k0)*kernel_filter_pitch+64'(c0)*kernel_channel_pitch+(tap_mode ? 64'(tap_r)*S+tap_s : 0);
          packed_input<=0;
          tile_c<=C-c0<c_step?C-c0:c_step;
          patch_h<=CFG_WIDTH'(clipped_h);patch_w<=CFG_WIDTH'(clipped_w);
          patch_i<=CFG_WIDTH'(clip_i);patch_j<=CFG_WIDTH'(clip_j);
          local_pad_i<=CFG_WIDTH'(clip_i-raw_i);local_pad_j<=CFG_WIDTH'(clip_j-raw_j);
          bank_index<=0;word_index<=0;
          state<=(clipped_h!=0 && clipped_w!=0)?INPUT_READ:KERNEL_READ;
        end
        // Issue a read, then consume its registered return in INPUT_WRITE.
        // This is intentionally two states per externally transferred operand.
        INPUT_READ: state<=INPUT_WRITE;
        // Deposit one input value locally. Advance the external address by one
        // inside a row, by W from its saved row base, or by H*W across channels.
        INPUT_WRITE: begin
          if(word_index+1<patch_words) begin
            if(dma_column+1<patch_w) begin dma_column<=dma_column+1'b1;input_dma_addr<=input_dma_addr+1;end
            else begin dma_column<=0;dma_row<=dma_row+1'b1;input_row_base<=input_row_base+W;input_dma_addr<=input_row_base+W;end
          end else begin
            dma_column<=0;dma_row<=0;
            input_channel_base<=input_channel_base+input_channel_pitch;
            input_row_base<=input_channel_base+input_channel_pitch;input_dma_addr<=input_channel_base+input_channel_pitch;
          end
          packed_input<=(word_index%8==7 || word_index+1==patch_words) ? 0 : next_packed_input;
          state<=INPUT_READ;
          if(word_index+1<patch_words) word_index<=word_index+1'b1;
          else begin
            word_index<=0;
            if(bank_index+1<tile_c) bank_index<=bank_index+1'b1;
            else begin bank_index<=0;state<=KERNEL_READ;end
          end
        end
        // The same one-read-edge/one-local-write-edge protocol applies to weights.
        KERNEL_READ: state<=KERNEL_WRITE;
        // Full kernels are contiguous within each filter's selected C chunk.
        // Single-tap fallback jumps by R*S between channels for that fixed tap.
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
        // Pulse core start once; WAIT_CORE holds until stored local results exist.
        START_CORE: state<=WAIT_CORE;
        // Continue through s, then r in fallback, then C chunks. continue_sum
        // keeps local output SRAM partial sums across these core invocations.
        WAIT_CORE: if(core_done) begin
          if(tap_mode && tap_s+1<S) begin tap_s<=tap_s+1'b1;tap_j_offset<=tap_j_offset+$signed(64'(dilation_j));state<=PREPARE;end
          else if(tap_mode && tap_r+1<R) begin tap_s<=0;tap_r<=tap_r+1'b1;tap_j_offset<=0;tap_i_offset<=tap_i_offset+$signed(64'(dilation_i));state<=PREPARE;end
          else if(c0+tile_c<C) begin
            c0<=c0+tile_c;tap_r<=0;tap_s<=0;tap_i_offset<=0;tap_j_offset<=0;state<=PREPARE;
          end else begin bank_index<=0;word_index<=0;state<=OUTPUT_READ;end
        end
        // Read local output SRAM one edge before writing the external result.
        OUTPUT_READ: state<=OUTPUT_WRITE;
        // Store each q in the tile, then select the next filter using pitch P*Q.
        // Physical local output bank index is k within the current K tile.
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
        // Advance q tiles first; then p rows; then K tiles; finally images n.
        // Row/column input origins follow stride increments and reset on wrap.
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
