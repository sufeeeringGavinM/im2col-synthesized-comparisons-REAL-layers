`timescale 1ns/1ps
// NHWC SHARED ADDRESS WRAPPER: one spatial address serves all channel banks.
// Each array row selects its own channel bank and delays this shared request.
// The parent keeps this generator alive for the whole local job. clear restarts
// a tap scan; job_clear repeats arithmetic setup. lookahead accounts for SRAM latency.
module im2col_addr_gen #(parameter CFG_WIDTH=32,POSITION_WIDTH=8,ADDR_WIDTH=8) (
 input clk,clear,job_clear,
 input [CFG_WIDTH-1:0] cfg_N,cfg_H,cfg_W,cfg_Q,cfg_R,cfg_S,
 input [CFG_WIDTH-1:0] cfg_pad_i,cfg_pad_j,cfg_stride_i,cfg_stride_j,cfg_dilation_i,cfg_dilation_j,r,s,
 output [ADDR_WIDTH-1:0] addr,output valid,ready
);
 wire [0:0][63:0] linear_addr;
 wire [0:0] lane_valid;
 linear_address_counter #(.CFG_WIDTH(CFG_WIDTH),.LANES(1)) u_address (
  .clk(clk),.job_clear(job_clear),.position_clear(clear),.advance(1'b1),.lookahead(1'b1),
  .N(cfg_N),.H(cfg_H),.W(cfg_W),.Q(cfg_Q),.R(cfg_R),.S(cfg_S),
  .pad_i(cfg_pad_i),.pad_j(cfg_pad_j),.stride_i(cfg_stride_i),.stride_j(cfg_stride_j),
  .dilation_i(cfg_dilation_i),.dilation_j(cfg_dilation_j),.r(r),.s(s),
  .ready(ready),.valid(lane_valid),.linear_addr(linear_addr));
 // The public address width is the local SRAM width; validity is kept separately.
 assign valid=lane_valid[0];assign addr=ADDR_WIDTH'(linear_addr[0]);
endmodule
