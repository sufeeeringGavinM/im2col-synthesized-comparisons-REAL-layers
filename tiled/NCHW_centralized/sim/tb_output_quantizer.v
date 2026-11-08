`timescale 1ns/1ps
module tb_output_quantizer;
  reg signed [31:0] value;reg enable,nearest;reg [4:0] shift;
  wire signed [31:0] result;
  integer f,n=0,rc,en,mode,sh;reg [31:0] v,want;
  string file_name;
  output_quantizer dut(value,enable,nearest,shift,result);
  initial begin
    if(!$value$plusargs("FILE=%s",file_name)) $fatal(1,"Missing vectors");
    f=$fopen(file_name,"r");if(!f)$fatal(1,"Cannot open vectors");
    while(!$feof(f))begin
      rc=$fscanf(f,"%h %h %h %h %h\n",en,mode,sh,v,want);
      if(rc==5)begin enable=en;nearest=mode;shift=sh;value=v;#1;
        if(result!==want)$fatal(1,"Quant mismatch en=%d nearest=%d shift=%d value=%h want=%h got=%h",en,mode,sh,v,want,result);
        n=n+1;
      end
    end
    $display("PASS: %0d quantization vectors",n);$finish;
  end
endmodule
