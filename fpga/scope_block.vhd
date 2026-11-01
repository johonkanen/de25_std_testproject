------------------------------------------------------------------------
-- scope_block - the oscilloscope (fpga_scope's scope_capture) on the
-- register bus, with a read window for its captures (docs/plan_scope.md,
-- phase 1).
--
--   registers g_base_address + 0..22   the scope's own registers (the header
--                                      of source/fpga_scope/source/
--                                      scope_capture.vhd is the map)
--   registers g_window .. g_window + 4*g_depth - 1
--                                      the last capture, read only, in time
--                                      order: sample s is words 4*s..4*s+3,
--                                      word 4*s+k holds channel 2k in bits
--                                      31:16 and channel 2k+1 in bits 15:0
--
-- Over LWH2F register n is at byte offset 16*n (axi_lwh2f_bridge.vhd), so
-- with the defaults the window is LWH2F 0x80000..0xBFFF0.
--
-- A window read sets the capture's read address and answers
-- scope_read_latency clocks later; the bus reply goes out on the next
-- clock (6 clocks from request to reply here, inside the bridge's read
-- timeout).
--
-- Probes must be in this clock's domain (synchronise anything else first).
-- No deep capture: the capture port is left unconnected (phase 2 connects
-- it to the DDR writer).
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use work.fpga_interconnect_pkg.all;
    use work.scope_pkg.all;

entity scope_block is
    generic (
        g_base_address : natural := 256;
        g_window       : natural := 16#8000#;
        g_depth        : natural := 4096;          -- samples, a power of two
        g_probes       : natural range 1 to 56;
        g_probe_table  : probe_table_array
    );
    port (
        clock   : in  std_logic;
        bus_in  : in  fpga_interconnect_record;
        bus_out : out fpga_interconnect_record;
        probes  : in  scope_sample_array(0 to g_probes-1)
    );
end entity scope_block;

architecture rtl of scope_block is

    constant window_words : natural := g_depth * words_per_sample;

    signal scope_bus_out  : fpga_interconnect_record := init_fpga_interconnect;
    signal window_bus_out : fpga_interconnect_record := init_fpga_interconnect;

    signal read_address : natural range 0 to window_words-1 := 0;
    signal read_data    : std_logic_vector(31 downto 0);
    -- a window read in flight: bit i set i+1 clocks after its address
    signal pending      : std_logic_vector(scope_read_latency-1 downto 0) := (others => '0');

begin

    bus_out <= scope_bus_out and window_bus_out;

    u_scope : entity work.scope_capture
        generic map (
            g_base_address => g_base_address,
            g_depth        => g_depth,
            g_deep_records => 2**10,               -- no deep capture here
            g_probes       => g_probes,
            g_probe_table  => g_probe_table
        )
        port map (
            clock        => clock,
            bus_in       => bus_in,
            bus_out      => scope_bus_out,
            probes       => probes,
            read_address => read_address,
            read_data    => read_data,
            capture_reset   => open,
            capture_write   => open,
            capture_data    => open,
            capture_flush   => open
        );

    window : process (clock) is
    begin
        if rising_edge(clock) then
            init_bus(window_bus_out);
            pending <= pending(pending'high-1 downto 0) & '0';

            if data_is_requested_from_address_range(bus_in, g_window, g_window + window_words) then
                read_address <= get_address(bus_in) - g_window;
                pending(0)   <= '1';
            end if;

            if pending(pending'high) = '1' then
                write_data_to_address(window_bus_out, 0, read_data);
            end if;
        end if;
    end process window;

end architecture rtl;
