# ModelSim do script to test bitcount.sv using tb_bitcount.sv
#
# set up the "work" library
vlib work
# compile our SystemVerilog files
vlog bitsum.sv
vlog tb_bitsum.sv
# point the simulator at the compiled design
vsim work.tb_bitcount
# run simulation for 200 million cycles
run 200000000
quit
