------------------------------------------------------------------------
-- axi_lwh2f_bridge - AXI4 (the HPS's lwhps2fpga / LWH2F lightweight
-- bridge) to fpga_interconnect converter, so the register block in
-- uart_register_block.vhd is reachable from HPS software over LWH2F,
-- exactly like it already is over the fabric UART.
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

entity axi_lwh2f_bridge is
    generic (
        package axi_interconnect_pkg is new work.fpga_interconnect_generic_pkg generic map (<>)
    );
    port (
        clock   : in  std_logic;
        resetn  : in  std_logic;

        -- write address channel
        awid    : in  std_logic_vector(3 downto 0);
        awaddr  : in  std_logic_vector(28 downto 0);
        awvalid : in  std_logic;
        awready : out std_logic;

        -- write data channel
        wdata   : in  std_logic_vector(31 downto 0);
        wstrb   : in  std_logic_vector(3 downto 0);
        wvalid  : in  std_logic;
        wready  : out std_logic;

        -- write response channel
        bid     : out std_logic_vector(3 downto 0);
        bresp   : out std_logic_vector(1 downto 0);
        bvalid  : out std_logic;
        bready  : in  std_logic;

        -- read address channel
        arid    : in  std_logic_vector(3 downto 0);
        araddr  : in  std_logic_vector(28 downto 0);
        arvalid : in  std_logic;
        arready : out std_logic;

        -- read data channel
        rid     : out std_logic_vector(3 downto 0);
        rdata   : out std_logic_vector(31 downto 0);
        rresp   : out std_logic_vector(1 downto 0);
        rlast   : out std_logic;
        rvalid  : out std_logic;
        rready  : in  std_logic;

        -- fpga_interconnect side: requests out, responses in
        bus_from_lwh2f : out axi_interconnect_pkg.fpga_interconnect_record := axi_interconnect_pkg.init_fpga_interconnect;
        bus_to_lwh2f   : in  axi_interconnect_pkg.fpga_interconnect_record := axi_interconnect_pkg.init_fpga_interconnect
    );
end axi_lwh2f_bridge;

architecture rtl of axi_lwh2f_bridge is

    use axi_interconnect_pkg.all;

    signal read_active        : std_logic := '0';
    signal read_trans_address : awaddr'subtype := (others => '0');
    signal request_data       : std_logic := '0';

    signal write_active       : std_logic := '0';
    signal write_data_active  : std_logic := '0';
    signal write_trans_address : awaddr'subtype := (others => '0');
    signal write_trans_data    : wdata'subtype  := (others => '0');

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
                awready <= '1';
            end if;
            if write_data_active = '0' then
                wready <= '1';
            end if;
            bvalid <= '0';
            if bvalid = '0'
                and bready = '1'
                and write_active = '1'
                and write_data_active = '1'
            then
                awready            <= '0';
                wready             <= '0';
                bvalid             <= '1';
                write_active       <= '0';
                write_data_active  <= '0';
            end if;

            if awvalid = '1' and write_active = '0' then
                write_active        <= '1';
                awready              <= '0';
                write_trans_address <= awaddr;
                bid                 <= awid;
            end if;

            write_actuated := wvalid = '1' and write_data_active = '0';
            if write_actuated then
                write_data_active <= '1';
                wready            <= '0';
                write_trans_data  <= wdata;
            end if;

            if write_active = '1' and write_data_active = '1' then
                bvalid <= '1';
                bresp  <= "00";
                write_data_to_address(bus_from_lwh2f
                    ,address => to_integer(unsigned(write_trans_address(15 + 4 downto 4)))
                    ,data    => write_trans_data
                    );
            end if;

            if resetn = '0' then
                bvalid            <= '0';
                awready           <= '0';
                wready            <= '0';
                write_active      <= '0';
                write_data_active <= '0';
            end if;

            ------------------------------------------------------------
            -- read
            ------------------------------------------------------------
            if read_active = '0' then
                arready <= '1';
            end if;
            if arvalid = '1' and read_active = '0' then
                arready       <= '0';
                read_trans_address <= araddr;
                rid           <= arid;
                rresp         <= "00";     -- OKAY
                rlast         <= '1';
                read_active   <= '1';
                request_data  <= '1';
                read_watchdog <= 7;
            end if;

            if rvalid = '1' and rready = '1' then
                arready     <= '1';
                rvalid      <= '0';
                read_active <= '0';
                rdata       <= (others => '0');
            end if;

            if request_data = '1'
                and write_active = '0'
                and write_data_active = '0'
                and bvalid = '0'
            then
                request_data <= '0';
                request_data_from_address(bus_from_lwh2f
                    ,to_integer(unsigned(read_trans_address(15 + 4 downto 4))));
            end if;

            if write_to_address_is_requested(bus_to_lwh2f, 0) or read_watchdog = 1 then
                read_watchdog <= 0;
                rvalid        <= '1';
                rdata         <= get_slv_data(bus_to_lwh2f);
            end if;

            if resetn = '0' then
                rvalid      <= '0';
                read_active <= '0';
            end if;

        end if;
    end process axi_to_interconnect_converter;

end rtl;
