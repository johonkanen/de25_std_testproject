------------------------------------------------------------------------
-- axi_lwh2f_bridge - AXI4 (the HPS's lwhps2fpga / LWH2F lightweight
-- bridge) to fpga_interconnect converter, so the register block in
-- register_block.vhd is reachable from HPS software over LWH2F.
--
-- Ported from ~/dev/datacenter_peak_shaving/fpga/agilex/de25/axi_led.vhd
-- (same author) - the state machine and the generic-package-parameter
-- pattern (so this entity compiles against any fpga_interconnect_pkg
-- instance, not just a hardcoded one) are unchanged; the demo LED/local
-- register bits are dropped.
--
-- Addressing: each fpga_interconnect register occupies a 16-byte (0x10)
-- slot in the AXI address space - awaddr/araddr bits [19:4] select the
-- register, matching axi_led's convention. E.g. register 3 (the loopback
-- register) is at LWH2F byte offset 0x30.
--
-- One AXI4 transaction in flight at a time (no outstanding/pipelined
-- requests) - fine for a register-poking test interface, not a
-- high-throughput DMA path. A read that gets no response within 7 clocks
-- (nothing at that address, or the register file busy with the other
-- master) returns 0 rather than hanging the AXI bus forever.
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use work.hps_axi_pkg.all;

entity axi_lwh2f_bridge is
    generic (
        package axi_interconnect_pkg is new work.fpga_interconnect_generic_pkg generic map (<>)
    );
    port (
        clock   : in  std_logic;
        resetn  : in  std_logic;

        -- the lwhps2fpga bus (hps_axi_pkg.vhd): requests in, answers out.
        -- Single beats only: the burst fields are not looked at.
        axi_m2s : in  t_lwh2f_m2s;
        axi_s2m : out t_lwh2f_s2m;

        -- fpga_interconnect side: requests out, responses in
        bus_from_lwh2f : out axi_interconnect_pkg.fpga_interconnect_record := axi_interconnect_pkg.init_fpga_interconnect;
        bus_to_lwh2f   : in  axi_interconnect_pkg.fpga_interconnect_record := axi_interconnect_pkg.init_fpga_interconnect
    );
end axi_lwh2f_bridge;

architecture rtl of axi_lwh2f_bridge is

    use axi_interconnect_pkg.all;

    signal read_active        : std_logic := '0';
    signal read_trans_address : std_logic_vector(28 downto 0) := (others => '0');
    signal request_data       : std_logic := '0';

    signal write_active       : std_logic := '0';
    signal write_data_active  : std_logic := '0';
    signal write_trans_address : std_logic_vector(28 downto 0) := (others => '0');
    signal write_trans_data    : std_logic_vector(31 downto 0) := (others => '0');

    signal read_watchdog : natural range 0 to 15 := 0;

begin

    axi_to_interconnect_converter : process (clock) is
        variable write_actuated : boolean := false;
    begin
        if rising_edge(clock) then

            if read_watchdog > 0 then
                read_watchdog <= read_watchdog - 1;
            end if;

            init_bus(bus_from_lwh2f);

            ------------------------------------------------------------
            -- write
            ------------------------------------------------------------
            if write_active = '0' then
                axi_s2m.awready <= '1';
            end if;
            if write_data_active = '0' then
                axi_s2m.wready <= '1';
            end if;
            axi_s2m.bvalid <= '0';
            if axi_s2m.bvalid = '0'
                and axi_m2s.bready = '1'
                and write_active = '1'
                and write_data_active = '1'
            then
                axi_s2m.awready            <= '0';
                axi_s2m.wready             <= '0';
                axi_s2m.bvalid             <= '1';
                write_active       <= '0';
                write_data_active  <= '0';
            end if;

            if axi_m2s.awvalid = '1' and write_active = '0' then
                write_active        <= '1';
                axi_s2m.awready              <= '0';
                write_trans_address <= axi_m2s.awaddr;
                axi_s2m.bid                 <= axi_m2s.awid;
            end if;

            write_actuated := axi_m2s.wvalid = '1' and write_data_active = '0';
            if write_actuated then
                write_data_active <= '1';
                axi_s2m.wready            <= '0';
                write_trans_data  <= axi_m2s.wdata;
            end if;

            if write_active = '1' and write_data_active = '1' then
                axi_s2m.bvalid <= '1';
                axi_s2m.bresp  <= "00";
                write_data_to_address(bus_from_lwh2f
                    ,address => to_integer(unsigned(write_trans_address(15 + 4 downto 4)))
                    ,data    => write_trans_data
                    );
            end if;

            if resetn = '0' then
                axi_s2m.bvalid            <= '0';
                axi_s2m.awready           <= '0';
                axi_s2m.wready            <= '0';
                write_active      <= '0';
                write_data_active <= '0';
            end if;

            ------------------------------------------------------------
            -- read
            ------------------------------------------------------------
            if read_active = '0' then
                axi_s2m.arready <= '1';
            end if;
            if axi_m2s.arvalid = '1' and read_active = '0' then
                axi_s2m.arready       <= '0';
                read_trans_address <= axi_m2s.araddr;
                axi_s2m.rid           <= axi_m2s.arid;
                axi_s2m.rresp         <= "00";     -- OKAY
                axi_s2m.rlast         <= '1';
                read_active   <= '1';
                request_data  <= '1';
                read_watchdog <= 7;
            end if;

            if axi_s2m.rvalid = '1' and axi_m2s.rready = '1' then
                axi_s2m.arready     <= '1';
                axi_s2m.rvalid      <= '0';
                read_active <= '0';
                axi_s2m.rdata       <= (others => '0');
            end if;

            if request_data = '1'
                and write_active = '0'
                and write_data_active = '0'
                and axi_s2m.bvalid = '0'
            then
                request_data <= '0';
                request_data_from_address(bus_from_lwh2f
                    ,to_integer(unsigned(read_trans_address(15 + 4 downto 4))));
            end if;

            if write_to_address_is_requested(bus_to_lwh2f, 0) or read_watchdog = 1 then
                read_watchdog <= 0;
                axi_s2m.rvalid        <= '1';
                axi_s2m.rdata         <= get_slv_data(bus_to_lwh2f);
            end if;

            if resetn = '0' then
                axi_s2m.rvalid      <= '0';
                read_active <= '0';
            end if;

        end if;
    end process axi_to_interconnect_converter;

end rtl;
