// Sequential layer descriptor interface. AI assistance: Codex.
`timescale 1ns/1ps
module conv_chain #(
    parameter ARRAY_SIZE=10, BIT_WIDTH=8, ACC_WIDTH=32,
    parameter INPUT_ADDR_WIDTH=8, OUTPUT_ADDR_WIDTH=8, KERNEL_ADDR_WIDTH=8,
    parameter CFG_WIDTH=32, MEM_ADDR_WIDTH=32,
    parameter MEM_DATA_WIDTH=(ACC_WIDTH>BIT_WIDTH ? ACC_WIDTH : BIT_WIDTH)
) (
    input clk, nrst, descriptor_valid, descriptor_last,
    output descriptor_ready, output reg chain_busy, output chain_done,
    output busy, output done,
    input [CFG_WIDTH-1:0] cfg_N,cfg_C,cfg_H,cfg_W,cfg_K,cfg_R,cfg_S,cfg_P,cfg_Q,
    input [CFG_WIDTH-1:0] cfg_pad_i,cfg_pad_j,cfg_stride_i,cfg_stride_j,cfg_dilation_i,cfg_dilation_j,
    input [MEM_ADDR_WIDTH-1:0] cfg_input_base,cfg_kernel_base,cfg_output_base,
    input cfg_quantize,cfg_round_nearest,
    input [4:0] cfg_output_shift,
    output mem_re, mem_we,
    output [MEM_ADDR_WIDTH-1:0] mem_raddr,mem_waddr,
    input [MEM_DATA_WIDTH-1:0] mem_rdata,
    output [MEM_DATA_WIDTH-1:0] mem_wdata
);
  // Each valid/ready handshake launches one descriptor. No internal table.
  // The producer supplies addresses/geometries and marks the chain's final layer.
  reg last_layer;
  wire accept=descriptor_valid && descriptor_ready;
  assign descriptor_ready=nrst && !busy && !done;
  assign chain_done=done && last_layer;
  always @(posedge clk) begin
    if(!nrst) begin chain_busy<=0;last_layer<=0;end
    else begin
      if(accept) begin chain_busy<=1;last_layer<=descriptor_last;end
      else if(chain_done) chain_busy<=0;
    end
  end
  conv_accelerator #(
    .ARRAY_SIZE(ARRAY_SIZE),
    .BIT_WIDTH(BIT_WIDTH),
    .ACC_WIDTH(ACC_WIDTH),
    .INPUT_ADDR_WIDTH(INPUT_ADDR_WIDTH),
    .OUTPUT_ADDR_WIDTH(OUTPUT_ADDR_WIDTH),
    .KERNEL_ADDR_WIDTH(KERNEL_ADDR_WIDTH),
    .CFG_WIDTH(CFG_WIDTH),
    .MEM_ADDR_WIDTH(MEM_ADDR_WIDTH),
    .MEM_DATA_WIDTH(MEM_DATA_WIDTH)
  ) u_accelerator (
    .start(accept),
    .clk(clk),
    .nrst(nrst),
    .busy(busy),
    .done(done),
    .cfg_N(cfg_N),
    .cfg_C(cfg_C),
    .cfg_H(cfg_H),
    .cfg_W(cfg_W),
    .cfg_K(cfg_K),
    .cfg_R(cfg_R),
    .cfg_S(cfg_S),
    .cfg_P(cfg_P),
    .cfg_Q(cfg_Q),
    .cfg_pad_i(cfg_pad_i),
    .cfg_pad_j(cfg_pad_j),
    .cfg_stride_i(cfg_stride_i),
    .cfg_stride_j(cfg_stride_j),
    .cfg_dilation_i(cfg_dilation_i),
    .cfg_dilation_j(cfg_dilation_j),
    .cfg_input_base(cfg_input_base),
    .cfg_kernel_base(cfg_kernel_base),
    .cfg_output_base(cfg_output_base),
    .cfg_quantize(cfg_quantize),
    .cfg_round_nearest(cfg_round_nearest),
    .cfg_output_shift(cfg_output_shift),
    .mem_re(mem_re),
    .mem_we(mem_we),
    .mem_raddr(mem_raddr),
    .mem_waddr(mem_waddr),
    .mem_rdata(mem_rdata),
    .mem_wdata(mem_wdata)
  );
endmodule
