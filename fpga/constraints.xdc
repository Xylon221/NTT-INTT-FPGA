# Preliminary core-only timing target; this is not a board constraint file.
# A 10 ns requested period does not demonstrate an achieved 100 MHz clock.
create_clock -name core_clk -period 10.000 [get_ports clk]
# rst_n is a synchronous reset and remains a timed input path.
# Hold it low across a rising edge; constrain its board-level input delay.
# Add board-specific pins, I/O standards, input/output delays and clock resources
# before implementation or hardware testing.
