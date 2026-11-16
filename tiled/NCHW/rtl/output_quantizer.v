// Shared serialized output requantizer. AI assistance: Codex.
`timescale 1ns/1ps
module output_quantizer #(parameter ACC_WIDTH=32, BIT_WIDTH=8)(
    input signed [ACC_WIDTH-1:0] value,
    input enable, round_nearest,
    input [4:0] shift,
    input [31:0] multiplier,
    output reg signed [ACC_WIDTH-1:0] result
);
  // A nonnegative scale numerator. Zero-extension prevents bit31 from becoming
  // a sign bit. ACC_WIDTH+32 bits retain the full signed accumulator product.
  localparam PRODUCT_WIDTH=ACC_WIDTH+32;
  wire signed [PRODUCT_WIDTH-1:0] product =
      $signed(value) * $signed({1'b0,multiplier});
  reg signed [PRODUCT_WIDTH:0] scaled;
  reg guard_bit, sticky_bit, increment;
  integer b;
  always @* begin
    scaled=$signed({product[PRODUCT_WIDTH-1],product}) >>> shift;
    guard_bit=0; sticky_bit=0; increment=0;
    if(shift!=0) begin
      guard_bit=product[shift-1];
      for(b=0;b<PRODUCT_WIDTH;b=b+1)
        if(b<shift-1) sticky_bit=sticky_bit | product[b];
      // Start with floor; increment positive ties and negative non-ties only.
      increment=round_nearest && guard_bit && (!product[PRODUCT_WIDTH-1] || sticky_bit);
    end
    scaled=scaled+$signed({{PRODUCT_WIDTH{1'b0}},increment});
    result=value;
    if(enable) begin
      if(scaled > $signed((PRODUCT_WIDTH+1)'((1 << (BIT_WIDTH-1))-1)))
        result=ACC_WIDTH'((1 << (BIT_WIDTH-1))-1);
      else if(scaled < -$signed((PRODUCT_WIDTH+1)'(1 << (BIT_WIDTH-1))))
        result=-$signed(ACC_WIDTH'(1 << (BIT_WIDTH-1)));
      else result=scaled[ACC_WIDTH-1:0];
    end
  end
endmodule
