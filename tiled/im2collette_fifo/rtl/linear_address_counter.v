`timescale 1ns/1ps
// Shared job pitches; streaming addresses use only additions and carry tests.
module linear_address_counter #(parameter CFG_WIDTH=32, LANES=1,
    INDEX_WIDTH=(LANES>1?$clog2(LANES):1)) (
    input clk, job_clear, position_clear, advance, lookahead,
    input [CFG_WIDTH-1:0] N,H,W,Q,R,S,
    input [CFG_WIDTH-1:0] pad_i,pad_j,stride_i,stride_j,dilation_i,dilation_j,r,s,
    output ready,
    output [LANES-1:0] valid,
    output [LANES-1:0][63:0] linear_addr
);
  reg [2:0] setup;
  reg initialized;
  reg [INDEX_WIDTH-1:0] seed_index;
  reg signed [63:0] row_pitch,col_step,row_step,tap_col_step,tap_row_step;
  reg signed [63:0] pad_col,pad_row,column_span,batch_correction,row_correction;
  reg [CFG_WIDTH-1:0] seed_n,seed_q,jump_n,jump_q;
  reg signed [63:0] seed_h,seed_w,seed_addr,jump_h,jump_w,jump_addr;
  reg [CFG_WIDTH-1:0] initial_n[0:LANES-1],initial_q[0:LANES-1];
  reg signed [63:0] initial_h[0:LANES-1],initial_w[0:LANES-1],initial_addr[0:LANES-1];
  reg [CFG_WIDTH-1:0] current_n[0:LANES-1],current_q[0:LANES-1];
  reg signed [63:0] current_h[0:LANES-1],current_w[0:LANES-1],current_addr[0:LANES-1];
  reg [CFG_WIDTH-1:0] saved_r,saved_s;
  reg signed [63:0] tap_h,tap_w,tap_addr,tap_row_addr;
  wire change_tap=r!=saved_r || s!=saved_s;
  wire signed [63:0] active_h=change_tap && s==0 ? tap_h+$signed({1'b0,dilation_i}) : tap_h;
  wire signed [63:0] active_w=change_tap ? (s==0 ? -$signed({1'b0,pad_j}) : tap_w+$signed({1'b0,dilation_j})) : tap_w;
  wire signed [63:0] active_addr=change_tap ? (s==0 ? tap_row_addr+tap_row_step : tap_addr+tap_col_step) : tap_addr;
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
        0: begin
          row_pitch<=$signed({1'b0,W})*$signed({1'b0,N});
          col_step<=$signed({1'b0,stride_j})*$signed({1'b0,N});
          tap_col_step<=$signed({1'b0,dilation_j})*$signed({1'b0,N});
          pad_col<=$signed({1'b0,pad_j})*$signed({1'b0,N});
          column_span<=$signed({1'b0,Q})*$signed({1'b0,stride_j});
          setup<=1;
        end
        1: begin
          row_step<=$signed({1'b0,stride_i})*row_pitch;
          tap_row_step<=$signed({1'b0,dilation_i})*row_pitch;
          pad_row<=$signed({1'b0,pad_i})*row_pitch;
          batch_correction<=col_step-$signed({1'b0,N});
          setup<=2;
        end
        2: begin
          row_correction<=row_step-$signed({1'b0,Q})*col_step;
          tap_h<=-$signed({1'b0,pad_i});tap_w<=-$signed({1'b0,pad_j});
          tap_addr<=-pad_row-pad_col;tap_row_addr<=-pad_row-pad_col;
          setup<=3;
        end
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
        if(position_clear) begin
          current_n[lane]<=initial_n[lane];current_q[lane]<=initial_q[lane];
          current_h[lane]<=initial_h[lane];current_w[lane]<=initial_w[lane];current_addr[lane]<=initial_addr[lane];
        end else if(advance) begin
          current_n[lane]<=next_n;current_q[lane]<=next_q;
          current_h[lane]<=next_h;current_w[lane]<=next_w;current_addr[lane]<=next_addr;
        end
      end
    end
    wire signed [63:0] h=(position_clear ? initial_h[lane] : lookahead ? next_h : current_h[lane])+active_h;
    wire signed [63:0] w=(position_clear ? initial_w[lane] : lookahead ? next_w : current_w[lane])+active_w;
    wire signed [63:0] a=(position_clear ? initial_addr[lane] : lookahead ? next_addr : current_addr[lane])+active_addr;
    assign valid[lane]=ready && h>=0 && h<$signed({1'b0,H}) && w>=0 && w<$signed({1'b0,W});
    assign linear_addr[lane]=valid[lane] ? a : 0;
  end endgenerate
endmodule
