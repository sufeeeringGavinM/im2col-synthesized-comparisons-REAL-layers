// One output channel's kernel memory with synchronous reads.
`timescale 1ns / 1ps
// ONE FILTER'S KERNEL SRAM: one operand per word, one synchronous read port.
// read_active masks unused logical filter/reduction terms with zero; it does not
// clear memory. A read issued before an edge is available after that edge.
// No reset clears the SRAM; preload writes establish its meaningful contents.
module kernel_bank #(parameter BIT_WIDTH = 8, ADDR_WIDTH = 8) (
    input clk, we, read_enable, read_active,
    input [ADDR_WIDTH-1:0] waddr, raddr,
    input [BIT_WIDTH-1:0] wdata,
    output reg [BIT_WIDTH-1:0] rdata
);
  reg [BIT_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];
  always @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
    if (read_enable) rdata <= read_active ? mem[raddr] : {BIT_WIDTH{1'b0}};
  end
endmodule
