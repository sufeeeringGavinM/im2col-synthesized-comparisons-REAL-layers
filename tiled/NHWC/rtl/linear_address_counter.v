`timescale 1ns/1ps
// Shared job pitches; streaming addresses use only additions and carry tests.
// INCREMENTAL ADDRESS GENERATION, within ONE channel's local input SRAM.
// Logical coordinates: h=p*stride_i+r*dilation_i-pad_i;
//                      w=q*stride_j+s*dilation_j-pad_j.
// Local word address: ((h*W)+w)*N+n; this is not the external NCHW file offset.
// _i means height (pad_h/stride_h/dil_h); _j means width (pad_w/stride_w/dil_w).
// Instead of recomputing products for every access, setup saves increments.
// Each address lane then adds those increments and applies wrap corrections.
// LANES counts addresses generated together, not physical systolic-array rows.
// NHWC/explicit use one lane; the packet feeder uses eight lanes.
module linear_address_counter #(parameter CFG_WIDTH=32, LANES=1,
    // Bits to select a seed lane; force at least one bit for scalar operation.
    INDEX_WIDTH=(LANES>1?$clog2(LANES):1)) (
    // job_clear repeats all setup; position_clear only restores initial_*.
    // advance accepts one LANES-position movement; otherwise counters hold.
    // lookahead selects next_* for the output before current_* registers update.
    input clk, job_clear, position_clear, advance, lookahead,
    input [CFG_WIDTH-1:0] N,H,W,Q,R,S,
    input [CFG_WIDTH-1:0] pad_i,pad_j,stride_i,stride_j,dilation_i,dilation_j,r,s,
    // ready: arithmetic and seeds are prepared. valid: final h/w is in bounds.
    // linear_addr is a local SRAM word index, with padding reported separately.
    output ready,
    output [LANES-1:0] valid,
    output [LANES-1:0][63:0] linear_addr
);
  // setup=0/1/2 prepares dependent arithmetic; setup=3 writes one lane seed per edge.
  // initialized/ready become true after all LANES starting positions are saved.
  reg [2:0] setup;
  reg initialized;
  // "Seed" means a starting counter value, not a random number.
  // seed_index selects which address lane is currently being initialized.
  reg [INDEX_WIDTH-1:0] seed_index;
  // A pitch is an address distance, measured in SRAM words, not bytes.
  // row_pitch=W*N: next input row; col_step=stride_w*N: next output column.
  // row_step=stride_h*W*N: next output-row origin.
  // tap_col_step=dil_w*N and tap_row_step=dil_h*W*N: move kernel taps.
  // These products are computed during setup, then reused as adder inputs.
  reg signed [63:0] row_pitch,col_step,row_step,tap_col_step,tap_row_step;
  // pad_col=pad_w*N; pad_row=pad_h*W*N. Their negatives form the first tap origin.
  // column_span=Q*stride_w is a coordinate distance: reset w after Q columns.
  // batch_correction=col_step-N adjusts an address when image index n wraps.
  // row_correction=row_step-Q*col_step adjusts it when output column q wraps.
  // Example N=1,W=32,Q=28,stride=1: ordinary +1; row wrap adds +1+4=+5.
  reg signed [63:0] pad_col,pad_row,column_span,batch_correction,row_correction;
  // Suffixes n/q identify image/output-column indices. Suffixes h/w/addr are
  // spatial-scan contributions, before adding the tap-and-padding contribution.
  // seed_* walks positions 0..LANES during setup. jump_* is the resulting
  // displacement over LANES positions, including its batch/row carry metadata.
  reg [CFG_WIDTH-1:0] seed_n,seed_q,jump_n,jump_q;
  reg signed [63:0] seed_h,seed_w,seed_addr,jump_h,jump_w,jump_addr;
  // initial_*: saved lane starting positions, restored at each spatial-scan restart.
  // current_*: live lane positions. For a logical position (n,p,q):
  // current_h=p*stride_h; current_w=q*stride_w;
  // current_addr=(p*stride_h*W+q*stride_w)*N+n. Tap offsets are separate.
  reg [CFG_WIDTH-1:0] initial_n[0:LANES-1],initial_q[0:LANES-1];
  reg signed [63:0] initial_h[0:LANES-1],initial_w[0:LANES-1],initial_addr[0:LANES-1];
  reg [CFG_WIDTH-1:0] current_n[0:LANES-1],current_q[0:LANES-1];
  reg signed [63:0] current_h[0:LANES-1],current_w[0:LANES-1],current_addr[0:LANES-1];
  // saved_r/s detect a new sequential kernel tap from the controller.
  // tap_h=r*dil_h-pad_h; tap_w=s*dil_w-pad_w;
  // tap_addr=(tap_h*W+tap_w)*N. tap_row_addr saves the s=0 origin so
  // advancing r restores the correct horizontal origin rather than extending it.
  reg [CFG_WIDTH-1:0] saved_r,saved_s;
  reg signed [63:0] tap_h,tap_w,tap_addr,tap_row_addr;
  // active_* includes a newly changed tap immediately, before the tap registers
  // update on the edge. s==0 denotes a new kernel row in the controller's order.
  wire change_tap=r!=saved_r || s!=saved_s;
  wire signed [63:0] active_h=change_tap && s==0 ? tap_h+$signed({1'b0,dilation_i}) : tap_h;
  wire signed [63:0] active_w=change_tap ? (s==0 ? -$signed({1'b0,pad_j}) : tap_w+$signed({1'b0,dilation_j})) : tap_w;
  wire signed [63:0] active_addr=change_tap ? (s==0 ? tap_row_addr+tap_row_step : tap_addr+tap_col_step) : tap_addr;
  // Seed enumeration follows for(p) for(q) for(n): n changes fastest.
  // Wrapping n advances q; wrapping both n and q advances the input row.
  // seed_next_* are combinational candidates, not extra stored counters.
  wire seed_batch_wrap=seed_n==N-1;
  wire seed_row_wrap=seed_batch_wrap && seed_q==Q-1;
  wire [CFG_WIDTH-1:0] seed_next_n=seed_batch_wrap ? 0 : seed_n+1'b1;
  wire [CFG_WIDTH-1:0] seed_next_q=seed_batch_wrap ? (seed_row_wrap ? 0 : seed_q+1'b1) : seed_q;
  wire signed [63:0] seed_next_h=seed_row_wrap ? seed_h+$signed({1'b0,stride_i}) : seed_h;
  wire signed [63:0] seed_next_w=seed_batch_wrap ? (seed_row_wrap ? 0 : seed_w+$signed({1'b0,stride_j})) : seed_w;
  wire signed [63:0] seed_next_addr=seed_addr+1+(seed_batch_wrap ? batch_correction : 0)+(seed_row_wrap ? row_correction : 0);
  assign ready=initialized && !job_clear;
  integer k;
  always @(posedge clk) begin
    if(job_clear) begin
      setup<=0;initialized<=0;seed_index<=0;
      seed_n<=0;seed_q<=0;seed_h<=0;seed_w<=0;seed_addr<=0;
      jump_n<=0;jump_q<=0;jump_h<=0;jump_w<=0;jump_addr<=0;
      row_pitch<=0;col_step<=0;row_step<=0;tap_col_step<=0;tap_row_step<=0;
      pad_col<=0;pad_row<=0;column_span<=0;batch_correction<=0;row_correction<=0;
      saved_r<=0;saved_s<=0;tap_h<=0;tap_w<=0;tap_addr<=0;tap_row_addr<=0;
      for(k=0;k<LANES;k=k+1) begin
        initial_n[k]<=0;initial_q[k]<=0;initial_h[k]<=0;initial_w[k]<=0;initial_addr[k]<=0;
      end
    end else if(!initialized) begin
      case(setup)
        // Stage 0: independent horizontal products and the input-row pitch.
        0: begin
          row_pitch<=$signed({1'b0,W})*$signed({1'b0,N});
          col_step<=$signed({1'b0,stride_j})*$signed({1'b0,N});
          tap_col_step<=$signed({1'b0,dilation_j})*$signed({1'b0,N});
          pad_col<=$signed({1'b0,pad_j})*$signed({1'b0,N});
          column_span<=$signed({1'b0,Q})*$signed({1'b0,stride_j});
          setup<=1;
        end
        // Stage 1: vertical products depend on the previous edge's row_pitch.
        1: begin
          row_step<=$signed({1'b0,stride_i})*row_pitch;
          tap_row_step<=$signed({1'b0,dilation_i})*row_pitch;
          pad_row<=$signed({1'b0,pad_i})*row_pitch;
          batch_correction<=col_step-$signed({1'b0,N});
          setup<=2;
        end
        // Stage 2: final wrap correction and signed, possibly negative tap origin.
        2: begin
          row_correction<=row_step-$signed({1'b0,Q})*col_step;
          tap_h<=-$signed({1'b0,pad_i});tap_w<=-$signed({1'b0,pad_j});
          tap_addr<=-pad_row-pad_col;tap_row_addr<=-pad_row-pad_col;
          setup<=3;
        end
        // Stage 3: one starting position per lane per edge. Scalar mode saves
        // position 0 and a one-position jump; packet mode saves 0..7 and a jump of 8.
        3: begin
          initial_n[seed_index]<=seed_n;initial_q[seed_index]<=seed_q;
          initial_h[seed_index]<=seed_h;initial_w[seed_index]<=seed_w;initial_addr[seed_index]<=seed_addr;
          seed_n<=seed_next_n;seed_q<=seed_next_q;seed_h<=seed_next_h;seed_w<=seed_next_w;seed_addr<=seed_next_addr;
          if(seed_index==LANES-1) begin
            jump_n<=seed_next_n;jump_q<=seed_next_q;
            jump_h<=seed_next_h;jump_w<=seed_next_w;jump_addr<=seed_next_addr;
            initialized<=1;
          end else seed_index<=seed_index+1'b1;
        end
      endcase
    end else if(change_tap) begin
      saved_r<=r;saved_s<=s;tap_h<=active_h;tap_w<=active_w;tap_addr<=active_addr;
      if(s==0) tap_row_addr<=active_addr;
    end
  end
  genvar lane;
  generate for(lane=0;lane<LANES;lane=lane+1) begin : g_position
    // Add the shared LANES-position jump, then correct carries through n and q.
    // These additions replace repeated position/N, position%N and position/Q.
    // For LANES>1 a next position skips the elements produced by the other lanes.
    wire [CFG_WIDTH:0] n_sum={1'b0,current_n[lane]}+{1'b0,jump_n};
    wire n_wrap=n_sum>={1'b0,N};
    wire [CFG_WIDTH:0] q_sum={1'b0,current_q[lane]}+{1'b0,jump_q}+n_wrap;
    wire q_wrap=q_sum>={1'b0,Q};
    wire [CFG_WIDTH-1:0] next_n=CFG_WIDTH'(n_wrap ? n_sum-N : n_sum);
    wire [CFG_WIDTH-1:0] next_q=CFG_WIDTH'(q_wrap ? q_sum-Q : q_sum);
    wire signed [63:0] next_h=current_h[lane]+jump_h+(q_wrap ? $signed({1'b0,stride_i}) : 0);
    wire signed [63:0] next_w=current_w[lane]+jump_w+(n_wrap ? $signed({1'b0,stride_j}) : 0)-(q_wrap ? column_span : 0);
    wire signed [63:0] next_addr=current_addr[lane]+jump_addr+(n_wrap ? batch_correction : 0)+(q_wrap ? row_correction : 0);
    // Seeds are relative to the tap. Tap changes do not require new divisions or products.
    always @(posedge clk) begin
      if(job_clear) begin
        current_n[lane]<=0;current_q[lane]<=0;current_h[lane]<=0;current_w[lane]<=0;current_addr[lane]<=0;
      end else if(!initialized && setup==3 && seed_index==lane) begin
        current_n[lane]<=seed_n;current_q[lane]<=seed_q;
        current_h[lane]<=seed_h;current_w[lane]<=seed_w;current_addr[lane]<=seed_addr;
      end else if(initialized) begin
        // Restart a spatial scan without repeating the setup multiplications.
        if(position_clear) begin
          current_n[lane]<=initial_n[lane];current_q[lane]<=initial_q[lane];
          current_h[lane]<=initial_h[lane];current_w[lane]<=initial_w[lane];current_addr[lane]<=initial_addr[lane];
        // Hold all position registers when the producer has not accepted a step.
        end else if(advance) begin
          current_n[lane]<=next_n;current_q[lane]<=next_q;
          current_h[lane]<=next_h;current_w[lane]<=next_w;current_addr[lane]<=next_addr;
        end
      end
    end
    // Choose saved/current/next position. lookahead presents the next request
    // early so synchronous SRAM can return it on the required feeding edge.
    // Add tap offsets only here; the spatial seeds are reusable across all taps.
    wire signed [63:0] h=(position_clear ? initial_h[lane] : lookahead ? next_h : current_h[lane])+active_h;
    wire signed [63:0] w=(position_clear ? initial_w[lane] : lookahead ? next_w : current_w[lane])+active_w;
    wire signed [63:0] a=(position_clear ? initial_addr[lane] : lookahead ? next_addr : current_addr[lane])+active_addr;
    // Negative padded coordinates must be checked before narrowing the address.
    // The consumer uses valid to inject zero; address zero alone is not padding.
    assign valid[lane]=ready && h>=0 && h<$signed({1'b0,H}) && w>=0 && w<$signed({1'b0,W});
    assign linear_addr[lane]=valid[lane] ? a : 0;
  end endgenerate
endmodule
