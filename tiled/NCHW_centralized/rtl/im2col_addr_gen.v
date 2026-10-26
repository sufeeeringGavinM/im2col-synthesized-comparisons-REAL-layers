`timescale 1ns/1ps
// One job initializer, a CRS seed counter, and incremental per-lane bank addresses.
// NCHW REDUCTION-ROW ADDRESS GENERATOR.
// Physical row lane handles term t=group_base+lane: c=t/(R*S), r=(t/S)%R, s=t%S.
// Each row needs a different input coordinate h=p*stride_h+r*dil_h-pad_h,
// w=q*stride_w+s*dil_w-pad_w. _i means height; _j means width in RTL names.
// For a valid stored input coordinate, the exact swizzle is:
//   slot=c*R*S+(h%R)*S+w%S; bank=slot%ARRAY_SIZE;
//   addr=((slot/ARRAY_SIZE)*ceil(H/R)*ceil(W/S)
//         +(h/R)*ceil(W/S)+w/S)*N+n.
// Setup precomputes quotient/remainder increments. Steady-state rows update
// bank/address registers with additions and carry checks, rather than redo this
// formula. Signed floor division is needed for negative padded starting origins.
module im2col_addr_gen #(parameter ARRAY_SIZE=4,CFG_WIDTH=32,ADDR_WIDTH=8,
 BANK_WIDTH=(ARRAY_SIZE>1?$clog2(ARRAY_SIZE):1)) (
 input clk,job_clear,clear,issue_advance,
 input [CFG_WIDTH-1:0] N,C,H,W,R,S,Q,
 input [CFG_WIDTH-1:0] pad_i,pad_j,stride_i,stride_j,dilation_i,dilation_j,group_base,
 output ready,
 output [ARRAY_SIZE-1:0] valid,
 output [ARRAY_SIZE-1:0][BANK_WIDTH-1:0] bank,
 output [ARRAY_SIZE-1:0][ADDR_WIDTH-1:0] addr
);
 localparam CW=2*CFG_WIDTH+2;
 localparam IW=(ARRAY_SIZE>1?$clog2(ARRAY_SIZE):1);
 // One divider services setup steps 0..7; pending prevents duplicate starts.
 // configured means shared arithmetic is ready; initialized means a row group
 // has received its saved starting addresses. They are different milestones.
 reg [3:0] setup_step;
 reg pending,configured;
 // tile_rows=ceil(H/R), tile_cols=ceil(W/S): coarse input-block dimensions.
 // Encoded names: sr=stride height, sc=stride width; dr=dilation height,
 // dc=dilation width. Final q/r means quotient/remainder, not output Q/kernel R.
 // Example scq=floor(stride_w/S), scr=stride_w%S.
 // initial_hr/wr are Euclidean remainders of -pad_h/-pad_w in R/S.
 reg [CFG_WIDTH-1:0] tile_rows,tile_cols,srq,scq,drq,dcq,srr,scr,drr,dcr,initial_hr,initial_wr;
 // initial_hq/wq are coarse block coordinates at the padded origin.
 // row_pitch=tile_cols*N: words between coarse block rows.
 // plane_pitch=tile_rows*tile_cols*N: words occupied by one swizzle slot group.
 // initial_address/bank start c=0,r=0,s=0 at p=q=n=0.
 reg signed [CW-1:0] initial_hq,initial_wq,row_pitch,plane_pitch,initial_address;
 reg [BANK_WIDTH-1:0] initial_bank;
 reg [CW-1:0] numerator,denominator;
 wire division_done;
 wire [CW-1:0] quotient,remainder;
 always @* begin
  numerator=0;denominator=1;
  case(setup_step)
   0:begin numerator=CFG_WIDTH'(H+R-1);denominator=R;end
   1:begin numerator=CFG_WIDTH'(W+S-1);denominator=S;end
   2:begin numerator=stride_i;denominator=R;end
   3:begin numerator=stride_j;denominator=S;end
   4:begin numerator=dilation_i;denominator=R;end
   5:begin numerator=dilation_j;denominator=S;end
   6:begin numerator=pad_i;denominator=R;end
   7:begin numerator=pad_j;denominator=S;end
  endcase
 end
 setup_divider #(.WIDTH(CW)) u_setup (
  .clk(clk),.clear(job_clear),.start(!job_clear && setup_step<8 && !pending),
  .numerator(numerator),.denominator(denominator),.done(division_done),.quotient(quotient),.remainder(remainder));
 // Nine precomputed moves: 0/1 horizontal stride without/with residue wrap;
 // 2/3 vertical stride without/with wrap; 4/5 horizontal dilation;
 // 6/7 vertical dilation; 8 next channel (slot += R*S).
 // A residue wrap can make slot_delta negative even while h or w increases.
 wire signed [CW-1:0] slot_delta[0:8];
 assign slot_delta[0]=$signed({1'b0,scr});
 assign slot_delta[1]=$signed({1'b0,scr})-$signed({1'b0,S});
 assign slot_delta[2]=$signed({1'b0,srr})*$signed({1'b0,S});
 assign slot_delta[3]=($signed({1'b0,srr})-$signed({1'b0,R}))*$signed({1'b0,S});
 assign slot_delta[4]=$signed({1'b0,dcr});
 assign slot_delta[5]=$signed({1'b0,dcr})-$signed({1'b0,S});
 assign slot_delta[6]=$signed({1'b0,drr})*$signed({1'b0,S});
 assign slot_delta[7]=($signed({1'b0,drr})-$signed({1'b0,R}))*$signed({1'b0,S});
 assign slot_delta[8]=$signed({1'b0,R})*$signed({1'b0,S});
 // Split each signed slot_delta into floor(delta/ARRAY_SIZE) planes and a
 // nonnegative bank_delta. address_delta combines plane and coarse-spatial
 // movement. If adding bank_delta wraps the bank index, add one more plane.
 reg signed [CW-1:0] plane_delta[0:8],address_delta[0:8];
 reg [BANK_WIDTH-1:0] bank_delta[0:8];
 // Verilog signed division truncates toward zero. Correct it to mathematical
 // floor so negative moves have a nonnegative remainder and correct bank carry.
 function automatic signed [CW-1:0] floor_banks(input signed [CW-1:0] value);
  reg signed [CW-1:0] divisor;
  begin
   divisor=ARRAY_SIZE;
   floor_banks=value/divisor;
   if(value<0 && value%divisor!=0) floor_banks=floor_banks-1;
  end
 endfunction
 // b and d are each below ARRAY_SIZE: at most one subtraction is needed.
 function automatic [BANK_WIDTH-1:0] hop_bank(input [BANK_WIDTH-1:0] b,d);
  reg [BANK_WIDTH:0] sum;
  begin sum={1'b0,b}+{1'b0,d};hop_bank=BANK_WIDTH'(sum>=ARRAY_SIZE ? sum-ARRAY_SIZE : sum);end
 endfunction
 // A bank-index carry crosses into the next bank plane in local SRAM.
 function automatic signed [CW-1:0] hop_addr(input signed [CW-1:0] a,input [BANK_WIDTH-1:0] b,d,input signed [CW-1:0] increment);
  reg [BANK_WIDTH:0] sum;
  begin sum={1'b0,b}+{1'b0,d};hop_addr=a+increment+(sum>=ARRAY_SIZE ? plane_pitch : 0);end
 endfunction
 wire [CFG_WIDTH-1:0] initial_slot=initial_hr*S+initial_wr;
 // TWO METADATA SEED SETS, not the two activation-data slots in banked_input.
 // A seed set stores starting h,w,remainders,bank,address for each array row.
 // write_slot is being prepared; active_slot is consumed by the current group.
 // seed_base/seed_group identify flattened CRS groups; write_index selects a row.
 // Next-group seed generation overlaps current-group execution.
 reg write_slot,active_slot,initialized;
 reg [1:0] seed_ready;
 reg [IW-1:0] write_index;
 reg [CFG_WIDTH-1:0] seed_base,current_group;
 reg [CFG_WIDTH-1:0] seed_group[0:1];
 reg signed [CW-1:0] seed_h[0:1][0:ARRAY_SIZE-1],seed_w[0:1][0:ARRAY_SIZE-1],seed_addr[0:1][0:ARRAY_SIZE-1];
 reg [CFG_WIDTH-1:0] seed_hr[0:1][0:ARRAY_SIZE-1],seed_wr[0:1][0:ARRAY_SIZE-1];
 reg [BANK_WIDTH-1:0] seed_bank[0:1][0:ARRAY_SIZE-1];
 // Seed producer walks for(c) for(r) for(s). kernel_hr/wr track h%R,w%S;
 // kernel_h/w track the signed coordinates used for padding checks.
 // kernel_row_* and channel_* save outer-loop origins when s or r resets.
 reg [CFG_WIDTH-1:0] kernel_r,kernel_s,kernel_hr,kernel_wr;
 reg signed [CW-1:0] kernel_h,kernel_w,kernel_addr,kernel_row_addr,channel_addr;
 reg [BANK_WIDTH-1:0] kernel_bank,kernel_row_bank,channel_bank;
 wire [CFG_WIDTH:0] kernel_col_sum={1'b0,kernel_wr}+{1'b0,dcr};
 wire [CFG_WIDTH:0] kernel_row_sum={1'b0,kernel_hr}+{1'b0,drr};
 wire kernel_col_wrap=kernel_col_sum>={1'b0,S};
 wire kernel_row_wrap=kernel_row_sum>={1'b0,R};
 wire [3:0] dc_move=kernel_col_wrap ? 5 : 4;
 wire [3:0] dr_move=kernel_row_wrap ? 7 : 6;
 wire [BANK_WIDTH-1:0] next_kernel_col_bank=hop_bank(kernel_bank,bank_delta[dc_move]);
 wire signed [CW-1:0] next_kernel_col_addr=hop_addr(kernel_addr,kernel_bank,bank_delta[dc_move],address_delta[dc_move]);
 wire [BANK_WIDTH-1:0] next_kernel_row_bank=hop_bank(kernel_row_bank,bank_delta[dr_move]);
 wire signed [CW-1:0] next_kernel_row_addr=hop_addr(kernel_row_addr,kernel_row_bank,bank_delta[dr_move],address_delta[dr_move]);
 wire [BANK_WIDTH-1:0] next_channel_bank=hop_bank(channel_bank,bank_delta[8]);
 wire signed [CW-1:0] next_channel_addr=hop_addr(channel_addr,channel_bank,bank_delta[8],address_delta[8]);
 // Switch groups only when the requested group's metadata is ready.
 // ready also excludes clear, so no input request escapes a pass reset.
 wire target_slot=initialized && current_group!=group_base ? !active_slot : active_slot;
 wire load_group=configured && (!initialized || current_group!=group_base) && seed_ready[target_slot] && seed_group[target_slot]==group_base;
 wire [CFG_WIDTH-1:0] total_terms=C*R*S;
 reg [CFG_WIDTH-1:0] batch_index,output_column;
 assign ready=configured && initialized && current_group==group_base && !clear && !job_clear;
 integer j;
 always @(posedge clk) begin
  if(job_clear) begin
   setup_step<=0;pending<=0;configured<=0;
   tile_rows<=0;tile_cols<=0;srq<=0;scq<=0;drq<=0;dcq<=0;srr<=0;scr<=0;drr<=0;dcr<=0;
   initial_hr<=0;initial_wr<=0;initial_hq<=0;initial_wq<=0;row_pitch<=0;plane_pitch<=0;initial_address<=0;initial_bank<=0;
   write_slot<=0;active_slot<=0;initialized<=0;seed_ready<=0;write_index<=0;seed_base<=0;current_group<=0;
   kernel_r<=0;kernel_s<=0;kernel_hr<=0;kernel_wr<=0;kernel_h<=0;kernel_w<=0;
   kernel_addr<=0;kernel_row_addr<=0;channel_addr<=0;kernel_bank<=0;kernel_row_bank<=0;channel_bank<=0;
   for(j=0;j<9;j=j+1) begin plane_delta[j]<=0;bank_delta[j]<=0;address_delta[j]<=0;end
  end else if(!configured) begin
   // Eight sequential divisions obtain block sizes and stride/dilation/padding
   // quotients/remainders. Multipliers below use their registered results.
   if(setup_step<8) begin
    if(!pending) pending<=1;
    if(division_done) begin
     pending<=0;setup_step<=setup_step+1'b1;
     case(setup_step)
      0:tile_rows<=CFG_WIDTH'(quotient);
      1:tile_cols<=CFG_WIDTH'(quotient);
      2:begin srq<=CFG_WIDTH'(quotient);srr<=CFG_WIDTH'(remainder);end
      3:begin scq<=CFG_WIDTH'(quotient);scr<=CFG_WIDTH'(remainder);end
      4:begin drq<=CFG_WIDTH'(quotient);drr<=CFG_WIDTH'(remainder);end
      5:begin dcq<=CFG_WIDTH'(quotient);dcr<=CFG_WIDTH'(remainder);end
      6:begin initial_hq<=-$signed(quotient)-(remainder!=0);initial_hr<=remainder!=0 ? R-CFG_WIDTH'(remainder) : 0;end
      7:begin initial_wq<=-$signed(quotient)-(remainder!=0);initial_wr<=remainder!=0 ? S-CFG_WIDTH'(remainder) : 0;end
     endcase
    end
   end else case(setup_step)
    // Convert signed slot moves into reusable bank and plane increments.
    8:begin
     row_pitch<=$signed({1'b0,tile_cols})*$signed({1'b0,N});
     for(j=0;j<9;j=j+1) begin
      plane_delta[j]<=floor_banks(slot_delta[j]);
      bank_delta[j]<=BANK_WIDTH'(slot_delta[j]-floor_banks(slot_delta[j])*ARRAY_SIZE);
     end
     setup_step<=9;
    end
    // Coarse input plane size in local SRAM words, including interleaved images.
    9:begin plane_pitch<=$signed({1'b0,tile_rows})*row_pitch;setup_step<=10;end
    // Merge coarse-coordinate movement with plane movement for each case.
    // Padding quotient/remainder calculations allow a negative starting origin;
    // invalid padded coordinates will be masked before a bank request is issued.
    10:begin
     address_delta[0]<=plane_delta[0]*plane_pitch+$signed({1'b0,scq})*$signed({1'b0,N});
     address_delta[1]<=plane_delta[1]*plane_pitch+($signed({1'b0,scq})+1)*$signed({1'b0,N});
     address_delta[2]<=plane_delta[2]*plane_pitch+$signed({1'b0,srq})*row_pitch;
     address_delta[3]<=plane_delta[3]*plane_pitch+($signed({1'b0,srq})+1)*row_pitch;
     address_delta[4]<=plane_delta[4]*plane_pitch+$signed({1'b0,dcq})*$signed({1'b0,N});
     address_delta[5]<=plane_delta[5]*plane_pitch+($signed({1'b0,dcq})+1)*$signed({1'b0,N});
     address_delta[6]<=plane_delta[6]*plane_pitch+$signed({1'b0,drq})*row_pitch;
     address_delta[7]<=plane_delta[7]*plane_pitch+($signed({1'b0,drq})+1)*row_pitch;
     address_delta[8]<=plane_delta[8]*plane_pitch;
     initial_bank<=BANK_WIDTH'(initial_slot%ARRAY_SIZE);
     initial_address<=$signed({1'b0,initial_slot/ARRAY_SIZE})*plane_pitch+initial_hq*row_pitch+initial_wq*$signed({1'b0,N});
     setup_step<=11;
    end
    11:begin
     configured<=1;
     kernel_h<=-$signed({1'b0,pad_i});kernel_w<=-$signed({1'b0,pad_j});kernel_hr<=initial_hr;kernel_wr<=initial_wr;
     kernel_addr<=initial_address;kernel_row_addr<=initial_address;channel_addr<=initial_address;
     kernel_bank<=initial_bank;kernel_row_bank<=initial_bank;channel_bank<=initial_bank;
    end
   endcase
  end else begin
   // Address metadata only: two seed sets permit initialization during computation.
   if(!seed_ready[write_slot] && seed_base<total_terms) begin
    if(write_index==0) seed_group[write_slot]<=seed_base;
    seed_h[write_slot][write_index]<=kernel_h;seed_w[write_slot][write_index]<=kernel_w;
    seed_hr[write_slot][write_index]<=kernel_hr;seed_wr[write_slot][write_index]<=kernel_wr;
    seed_bank[write_slot][write_index]<=kernel_bank;seed_addr[write_slot][write_index]<=kernel_addr;
    if(write_index==ARRAY_SIZE-1) begin
     seed_ready[write_slot]<=1;write_slot<=!write_slot;write_index<=0;seed_base<=seed_base+ARRAY_SIZE;
    end else write_index<=write_index+1'b1;
    if(kernel_s!=S-1) begin
     kernel_s<=kernel_s+1'b1;kernel_w<=kernel_w+$signed({1'b0,dilation_j});
     kernel_wr<=CFG_WIDTH'(kernel_col_wrap ? kernel_col_sum-S : kernel_col_sum);
     kernel_bank<=next_kernel_col_bank;kernel_addr<=next_kernel_col_addr;
    end else begin
     kernel_s<=0;kernel_w<=-$signed({1'b0,pad_j});kernel_wr<=initial_wr;
     if(kernel_r!=R-1) begin
      kernel_r<=kernel_r+1'b1;kernel_h<=kernel_h+$signed({1'b0,dilation_i});
      kernel_hr<=CFG_WIDTH'(kernel_row_wrap ? kernel_row_sum-R : kernel_row_sum);
      kernel_bank<=next_kernel_row_bank;kernel_addr<=next_kernel_row_addr;
      kernel_row_bank<=next_kernel_row_bank;kernel_row_addr<=next_kernel_row_addr;
     end else begin
      kernel_r<=0;kernel_h<=-$signed({1'b0,pad_i});kernel_hr<=initial_hr;
      kernel_bank<=next_channel_bank;kernel_addr<=next_channel_addr;
      kernel_row_bank<=next_channel_bank;kernel_row_addr<=next_channel_addr;
      channel_bank<=next_channel_bank;channel_addr<=next_channel_addr;
     end
    end
   end
   // Atomically install one complete row-seed set, then release that set.
   if(load_group) begin
    seed_ready[target_slot]<=0;active_slot<=target_slot;current_group<=group_base;initialized<=1;
   end
  end
 end
 // Shared stream order: n advances first, then q, then the input row origin.
 // issue_advance means every valid request for this vector has been scheduled;
 // it does not mean all responses have returned or the array consumed it yet.
 always @(posedge clk) begin
  if(job_clear || load_group) begin batch_index<=0;output_column<=0;end
  else if(ready && issue_advance) begin
   if(batch_index==N-1) begin batch_index<=0;output_column<=output_column==Q-1 ? 0 : output_column+1'b1;end
   else batch_index<=batch_index+1'b1;
  end
 end
 genvar lane;
 generate for(lane=0;lane<ARRAY_SIZE;lane=lane+1) begin : g_row
  // Per physical row: h/w are actual signed input coordinates.
  // hr/wr are their residues modulo R/S; first_w/first_wr restore q=0.
  // current_bank/address follow q; row_bank/address save the current p origin.
  // n is shared, so each row adds batch_index only at the final output.
  reg signed [CW-1:0] h,w,row_address,current_address,first_w;
  reg [CFG_WIDTH-1:0] hr,wr,first_wr;
  reg [BANK_WIDTH-1:0] row_bank,current_bank;
  // stride remainder + current residue selects wrapped/unwrapped increments.
  // The quotients were included in address_delta during setup.
  wire [CFG_WIDTH:0] col_sum={1'b0,wr}+{1'b0,scr};
  wire [CFG_WIDTH:0] row_sum={1'b0,hr}+{1'b0,srr};
  wire col_wrap=col_sum>={1'b0,S};
  wire row_wrap=row_sum>={1'b0,R};
  wire [1:0] col_move=col_wrap ? 1 : 0;
  wire [1:0] row_move=row_wrap ? 3 : 2;
  wire [BANK_WIDTH-1:0] advanced_row_bank=hop_bank(row_bank,bank_delta[row_move]);
  wire signed [CW-1:0] advanced_row_addr=hop_addr(row_address,row_bank,bank_delta[row_move],address_delta[row_move]);
  always @(posedge clk) begin
   if(job_clear) begin
    h<=0;w<=0;hr<=0;wr<=0;first_wr<=0;first_w<=0;row_address<=0;current_address<=0;row_bank<=0;current_bank<=0;
   end else if(load_group) begin
    h<=seed_h[target_slot][lane];w<=seed_w[target_slot][lane];first_w<=seed_w[target_slot][lane];
    hr<=seed_hr[target_slot][lane];wr<=seed_wr[target_slot][lane];first_wr<=seed_wr[target_slot][lane];
    row_address<=seed_addr[target_slot][lane];current_address<=seed_addr[target_slot][lane];
    row_bank<=seed_bank[target_slot][lane];current_bank<=seed_bank[target_slot][lane];
   // All images at the current p,q are issued before changing spatial coordinates.
   // At q wrap, restore horizontal origin and advance the saved vertical origin.
   end else if(ready && issue_advance && batch_index==N-1) begin
    if(output_column==Q-1) begin
     h<=h+$signed({1'b0,stride_i});w<=first_w;wr<=first_wr;
     hr<=CFG_WIDTH'(row_wrap ? row_sum-R : row_sum);
     row_address<=advanced_row_addr;current_address<=advanced_row_addr;
     row_bank<=advanced_row_bank;current_bank<=advanced_row_bank;
    end else begin
     w<=w+$signed({1'b0,stride_j});wr<=CFG_WIDTH'(col_wrap ? col_sum-S : col_sum);
     current_bank<=hop_bank(current_bank,bank_delta[col_move]);
     current_address<=hop_addr(current_address,current_bank,bank_delta[col_move],address_delta[col_move]);
    end
   end
  end
  // Last CRS group may not fill all rows. Both unused terms and padding are
  // invalid requests, so neither may read arbitrary truncated SRAM addresses.
  wire in_bounds=ready && group_base+lane<total_terms && h>=0 && h<$signed({1'b0,H}) && w>=0 && w<$signed({1'b0,W});
  assign valid[lane]=in_bounds;
  assign bank[lane]=in_bounds ? current_bank : 0;
  assign addr[lane]=in_bounds ? ADDR_WIDTH'(current_address+$signed({1'b0,batch_index})) : 0;
 end endgenerate
endmodule
