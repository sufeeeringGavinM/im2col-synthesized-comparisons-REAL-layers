`timescale 1ns/1ps
module im2col_addr_gen #(parameter CFG_WIDTH=32,ADDR_WIDTH=8,BUS_WORDS=8,PACKET_WORDS=8,
 OFFSET_WIDTH=(BUS_WORDS>1?$clog2(BUS_WORDS):1)) (
 input clk,clear,job_clear,advance,
 input [CFG_WIDTH-1:0] cfg_N,cfg_H,cfg_W,cfg_Q,cfg_R,cfg_S,
 input [CFG_WIDTH-1:0] cfg_pad_i,cfg_pad_j,cfg_stride_i,cfg_stride_j,cfg_dilation_i,cfg_dilation_j,r,s,position,
 output ready,
 output [PACKET_WORDS-1:0] valid,
 output [PACKET_WORDS-1:0][ADDR_WIDTH-1:0] word_addr,
 output [PACKET_WORDS-1:0][OFFSET_WIDTH-1:0] word_offset
);
 wire [PACKET_WORDS-1:0][63:0] linear_addr;
 linear_address_counter #(.CFG_WIDTH(CFG_WIDTH),.LANES(PACKET_WORDS)) u_address (
  .clk(clk),.job_clear(job_clear),.position_clear(clear),.advance(advance),.lookahead(1'b0),
  .N(cfg_N),.H(cfg_H),.W(cfg_W),.Q(cfg_Q),.R(cfg_R),.S(cfg_S),
  .pad_i(cfg_pad_i),.pad_j(cfg_pad_j),.stride_i(cfg_stride_i),.stride_j(cfg_stride_j),
  .dilation_i(cfg_dilation_i),.dilation_j(cfg_dilation_j),.r(r),.s(s),
  .ready(ready),.valid(valid),.linear_addr(linear_addr));
 genvar j;
 generate for(j=0;j<PACKET_WORDS;j=j+1) begin : g_position
  assign word_addr[j]=ADDR_WIDTH'(linear_addr[j]/BUS_WORDS);
  assign word_offset[j]=OFFSET_WIDTH'(linear_addr[j]%BUS_WORDS);
 end endgenerate
endmodule
