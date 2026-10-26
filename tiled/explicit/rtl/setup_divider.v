`timescale 1ns/1ps
module setup_divider #(parameter WIDTH=66) (
    input clk, clear, start,
    input [WIDTH-1:0] numerator, denominator,
    output reg done,
    output reg [WIDTH-1:0] quotient, remainder
);
  localparam COUNT_WIDTH=$clog2(WIDTH+1);
  reg busy;
  reg [COUNT_WIDTH-1:0] remaining;
  reg [WIDTH-1:0] divisor, work_quotient, work_remainder;
  wire [WIDTH:0] trial = {work_remainder,work_quotient[WIDTH-1]};
  wire subtract = trial >= {1'b0,divisor};
  wire [WIDTH:0] next_remainder = subtract ? trial-{1'b0,divisor} : trial;
  wire [WIDTH-1:0] next_quotient = {work_quotient[WIDTH-2:0],subtract};
  reg [COUNT_WIDTH-1:0] significant_bits;
  integer bit_index;
  always @* begin
    significant_bits=0;
    for(bit_index=0;bit_index<WIDTH;bit_index=bit_index+1)
      if(numerator[bit_index]) significant_bits=COUNT_WIDTH'(bit_index+1);
  end
  always @(posedge clk) begin
    if (clear) begin
      busy<=0; done<=0; remaining<=0;
      divisor<=0; work_quotient<=0; work_remainder<=0;
      quotient<=0; remainder<=0;
    end else begin
      done<=0;
      if (start && !busy) begin
        if(numerator<denominator || numerator==0) begin
          busy<=0;done<=1;quotient<=0;remainder<=numerator;
        end else begin
          busy<=1;remaining<=significant_bits;
          divisor<=denominator;
          work_quotient<=numerator << (WIDTH-significant_bits);work_remainder<=0;
        end
      end else if (busy) begin
        work_quotient<=next_quotient;
        work_remainder<=next_remainder[WIDTH-1:0];
        remaining<=remaining-1'b1;
        if (remaining==1) begin
          busy<=0; done<=1;
          quotient<=next_quotient;
          remainder<=next_remainder[WIDTH-1:0];
        end
      end
    end
  end
endmodule
