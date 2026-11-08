// Real memory reuse across three layers; reference data never drives memory.
`timescale 1ns/1ps
module tb_resnet8_chain;
  reg clk=0,nrst=0,descriptor_valid=0,descriptor_last;
  always #(clock_half_ns) clk=~clk;
  wire descriptor_ready,busy,done,chain_busy,chain_done,mem_re,mem_we;
  reg [31:0] cfg_N,cfg_C,cfg_H,cfg_W,cfg_K,cfg_R,cfg_S,cfg_P,cfg_Q;
  reg [31:0] cfg_pad_i,cfg_pad_j,cfg_stride_i,cfg_stride_j,cfg_dilation_i,cfg_dilation_j;
  reg [31:0] cfg_input_base,cfg_kernel_base,cfg_output_base;
  reg cfg_quantize,cfg_round_nearest;reg [4:0] cfg_output_shift;
  wire [31:0] mem_raddr,mem_waddr,mem_wdata;reg [31:0] mem_rdata;
  reg [31:0] memory[0:39999],expected[0:49151],descriptors[0:68];
  integer layer,j,off=0,base,outputs,cycles=0,accepted=0,started;
  integer first_cycle=0,chain_cycles=0;
  real clock_half_ns=5.0,chain_start_ns=0.0;
  initial if($value$plusargs("CLOCK_HALF_NS=%f",clock_half_ns)) begin end
  reg [63:0] phase_planning=0,phase_input_transfers=0,phase_kernel_transfers=0,
    phase_core_execution=0,phase_output_transfers=0,phase_tile_transitions=0,phase_descriptor_gaps=0;
  always @(posedge clk) if(nrst && chain_busy && !chain_done) begin
    if(busy) begin
      case(DUT.u_accelerator.state)
        DUT.u_accelerator.SETUP,DUT.u_accelerator.PLAN_TILE,DUT.u_accelerator.PREPARE:phase_planning<=phase_planning+1;
        DUT.u_accelerator.INPUT_READ,DUT.u_accelerator.INPUT_WRITE:phase_input_transfers<=phase_input_transfers+1;
        DUT.u_accelerator.KERNEL_READ,DUT.u_accelerator.KERNEL_WRITE:phase_kernel_transfers<=phase_kernel_transfers+1;
        DUT.u_accelerator.START_CORE,DUT.u_accelerator.WAIT_CORE:phase_core_execution<=phase_core_execution+1;
        DUT.u_accelerator.OUTPUT_READ,DUT.u_accelerator.OUTPUT_WRITE:phase_output_transfers<=phase_output_transfers+1;
        DUT.u_accelerator.NEXT_TILE:phase_tile_transitions<=phase_tile_transitions+1;
        default:phase_planning<=phase_planning+1;
      endcase
    end else phase_descriptor_gaps<=phase_descriptor_gaps+1;
  end
  integer live_input,live_words,live_output,live_outputs;
  string init_file,desc_file,expected_file;
  conv_chain DUT(.*);
  always @(posedge clk) begin
    cycles<=cycles+1;
    if(nrst)begin
      if(descriptor_valid && descriptor_ready)begin
        accepted<=accepted+1;
        live_input<=cfg_input_base;live_words<=cfg_N*cfg_C*cfg_H*cfg_W;
        live_output<=cfg_output_base;live_outputs<=cfg_N*cfg_K*cfg_P*cfg_Q;
      end
      if(mem_re)begin
        if($isunknown(mem_raddr)||mem_raddr>=40000)$fatal(1,"Bad chain read");
        mem_rdata<=memory[mem_raddr];
      end
      if(mem_we)begin
        if($isunknown(mem_waddr)||mem_waddr<live_output||mem_waddr>=live_output+live_outputs)$fatal(1,"Bad chain output address");
        if(mem_waddr>=live_input && mem_waddr<live_input+live_words)$fatal(1,"Overwrote live input");
        memory[mem_waddr]<=mem_wdata;
      end
      if(busy && descriptor_ready)$fatal(1,"Descriptor accepted while busy");
    end
  end
  initial begin
    if(!$value$plusargs("INIT=%s",init_file)||!$value$plusargs("DESC=%s",desc_file)||!$value$plusargs("EXPECTED=%s",expected_file))$fatal(1,"Missing chain fixture");
    $readmemh(init_file,memory);$readmemh(desc_file,descriptors);$readmemh(expected_file,expected,0,49151);
    repeat(3)@(negedge clk);nrst=1;
    for(layer=0;layer<3;layer=layer+1)begin
      @(negedge clk);
      {cfg_N,cfg_C,cfg_H,cfg_W,cfg_K,cfg_R,cfg_S,cfg_P,cfg_Q,
       cfg_pad_i,cfg_pad_j,cfg_stride_i,cfg_stride_j,cfg_dilation_i,cfg_dilation_j,
       cfg_input_base,cfg_kernel_base,cfg_output_base}=
      {descriptors[layer*23],descriptors[layer*23+1],descriptors[layer*23+2],descriptors[layer*23+3],descriptors[layer*23+4],descriptors[layer*23+5],descriptors[layer*23+6],descriptors[layer*23+7],descriptors[layer*23+8],descriptors[layer*23+9],descriptors[layer*23+10],descriptors[layer*23+11],descriptors[layer*23+12],descriptors[layer*23+13],descriptors[layer*23+14],descriptors[layer*23+15],descriptors[layer*23+16],descriptors[layer*23+17]};
      cfg_quantize=descriptors[layer*23+18];cfg_output_shift=descriptors[layer*23+19];cfg_round_nearest=descriptors[layer*23+20];descriptor_last=descriptors[layer*23+21];
      base=cfg_output_base;outputs=descriptors[layer*23+22];
      wait(descriptor_ready);descriptor_valid=1;@(posedge clk);started=cycles;if(layer==0)chain_start_ns=$realtime;
      @(negedge clk);descriptor_valid=0;
      // Poison live ports after handshake, including quantization and last flags.
      cfg_input_base=39999;cfg_output_base=39999;cfg_C=0;cfg_quantize=~cfg_quantize;cfg_output_shift=31;cfg_round_nearest=~cfg_round_nearest;descriptor_last=~descriptor_last;
      repeat(3)@(negedge clk);descriptor_valid=1;
      repeat(3)@(negedge clk);descriptor_valid=0;
      wait(done);if(layer==2)chain_cycles=$rtoi(($realtime-chain_start_ns)/(2*clock_half_ns)+0.5);#1;
      if(chain_done!==(layer==2)||!chain_busy)$fatal(1,"Chain completion mismatch");
      for(j=0;j<outputs;j=j+1)
        if(memory[base+j]!==expected[off+j])$fatal(1,"Chain layer%0d output%0d want%h got%h",layer,j,expected[off+j],memory[base+j]);
      $display("CHAIN_LAYER_PASS layer=%0d outputs=%0d cycles=%0d",layer,outputs,cycles-started-1);off=off+outputs;
      @(negedge clk);
    end
    repeat(2)@(negedge clk);
    if(chain_busy||accepted!=3)$fatal(1,"Descriptor count or chain busy incorrect");
    $display("CHAIN_METRICS cycles=%0d planning=%0d input_transfers=%0d kernel_transfers=%0d core_execution=%0d output_transfers=%0d tile_transitions=%0d descriptor_gaps=%0d",chain_cycles,phase_planning,phase_input_transfers,phase_kernel_transfers,phase_core_execution,phase_output_transfers,phase_tile_transitions,phase_descriptor_gaps);
    $display("PASS: actual 3-layer ping-pong chain, no intermediate replacement");$finish;
  end
  initial begin repeat(2000000)@(posedge clk);$fatal(1,"Chain watchdog");end
endmodule
