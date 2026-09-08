------------------------------------------------------------------------
-- de25_uart_top_tb - drive the real UART pins of de25_uart_top and check
-- the fpga_interconnect register responses.  8N1, LSB first, one stop bit,
-- g_clock_divider clocks per bit (overridden small here for speed).
--
--   nvc --std=2019 ...   (see sim/run.sh)
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity de25_uart_top_tb is
end entity;

architecture sim of de25_uart_top_tb is

    constant clock_period : time    := 20 ns;   -- 50 MHz
    constant divider      : natural := 16;      -- clocks per UART bit
    constant bit_time     : time    := divider * clock_period;

    signal clock    : std_logic := '0';
    signal reset_n  : std_logic := '0';
    signal sw       : std_logic_vector(9 downto 0) := "0000000000";
    signal key      : std_logic_vector(3 downto 0) := "1111";
    signal ledr     : std_logic_vector(9 downto 0);
    signal fpga_rx  : std_logic := '1';   -- host -> FPGA  (uart_rxd)
    signal fpga_tx  : std_logic;          -- FPGA -> host  (uart_txd)

    signal test_running : boolean := true;

    type byte_array is array (natural range <>) of std_logic_vector(7 downto 0);

begin

    clock <= not clock after clock_period / 2 when test_running else '0';

    dut : entity work.de25_uart_top
        generic map (g_clock_divider => divider, g_por_cycles => 64)
        port map (
            CLOCK0_50   => clock,
            CPU_RESET_n => reset_n,
            SW          => sw,
            KEY         => key,
            LEDR        => ledr,
            uart_rxd    => fpga_rx,
            uart_txd    => fpga_tx
        );

    stimulus : process

        variable errors : natural := 0;

        procedure send_byte (b : in std_logic_vector(7 downto 0)) is
        begin
            fpga_rx <= '0';                      -- start bit
            wait for bit_time;
            for i in 0 to 7 loop                 -- LSB first
                fpga_rx <= b(i);
                wait for bit_time;
            end loop;
            fpga_rx <= '1';                      -- stop bit
            wait for bit_time;
        end procedure;

        procedure recv_byte (signal line : in std_logic; b : out std_logic_vector(7 downto 0)) is
            variable v : std_logic_vector(7 downto 0);
        begin
            wait until line = '0';               -- start bit edge
            wait for bit_time / 2;               -- move to mid-bit
            wait for bit_time;                   -- first data bit
            for i in 0 to 7 loop
                v(i) := line;
                wait for bit_time;
            end loop;
            b := v;                              -- (line is now in the stop bit)
        end procedure;

        procedure bus_read (addr : in natural; result : out std_logic_vector(31 downto 0)) is
            variable rx : byte_array(0 to 6);
            variable a  : unsigned(15 downto 0) := to_unsigned(addr, 16);
        begin
            send_byte(x"02");
            send_byte(std_logic_vector(a(15 downto 8)));
            send_byte(std_logic_vector(a(7 downto 0)));
            for i in rx'range loop
                recv_byte(fpga_tx, rx(i));
            end loop;
            -- rx = [ len=6 , addr_hi , addr_lo , d31..24 , d23..16 , d15..8 , d7..0 ]
            result := rx(3) & rx(4) & rx(5) & rx(6);
        end procedure;

        procedure bus_write (addr : in natural; data : in std_logic_vector(31 downto 0)) is
            variable a : unsigned(15 downto 0) := to_unsigned(addr, 16);
        begin
            send_byte(x"04");
            send_byte(std_logic_vector(a(15 downto 8)));
            send_byte(std_logic_vector(a(7 downto 0)));
            send_byte(data(31 downto 24));
            send_byte(data(23 downto 16));
            send_byte(data(15 downto 8));
            send_byte(data(7 downto 0));
        end procedure;

        procedure check (name : in string; got, expected : in std_logic_vector(31 downto 0)) is
        begin
            if got = expected then
                report "PASS " & name & " = 0x" & to_hstring(got);
            else
                report "FAIL " & name & " : got 0x" & to_hstring(got)
                       & " expected 0x" & to_hstring(expected) severity error;
                errors := errors + 1;
            end if;
        end procedure;

        variable d : std_logic_vector(31 downto 0);
    begin
        reset_n <= '0';
        wait for 2 us;
        reset_n <= '1';
        wait for 2 us;

        bus_read(1, d);
        check("id (addr 1)", d, x"0000DE25");

        bus_write(3, x"DEADBEEF");
        bus_read(3, d);
        check("loopback (addr 3)", d, x"DEADBEEF");

        bus_write(3, x"12345678");
        bus_read(3, d);
        check("loopback (addr 3)", d, x"12345678");

        bus_write(5, x"000001AA");
        bus_read(5, d);
        check("LED register (addr 5)", d, x"000001AA");
        assert ledr(8 downto 0) = "110101010"
            report "FAIL LEDR[8:0] does not follow the LED register" severity error;

        sw <= "1010101010";
        wait for 1 us;
        bus_read(6, d);
        check("SW readback (addr 6)", d, x"000002AA");

        key <= "1101";                         -- KEY1 pressed (active low)
        wait for 1 us;
        bus_read(7, d);
        check("KEY readback (addr 7)", d, x"00000002");

        bus_read(4, d);
        bus_read(4, d);
        report "read counter after two reads = 0x" & to_hstring(d);

        if errors = 0 then
            report "==== ALL CHECKS PASSED ====" severity note;
        else
            report "==== " & integer'image(errors) & " CHECK(S) FAILED ====" severity failure;
        end if;

        test_running <= false;
        wait;
    end process;

end architecture;
