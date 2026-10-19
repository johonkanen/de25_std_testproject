------------------------------------------------------------------------
-- max6650_fan_control_tb - the MAX6650 driver against a behavioural MAX6650
-- on an I2C bus with pull-ups: the bus recovery (the chip starts mid-byte,
-- holding SDA low, as a core load can leave it), the setup order (no
-- Config 0x0A, Config 0x29 last), the status reads (Alarm Status read and
-- cleared, GPIO Status), Config stuck in full-on (0x09, plan §5.17b): the
-- driver sees it, sets the chip up again until it takes, counts it; and a
-- new target written to Speed. Run it with
--   ./build.sh sim     (or python3 fpga/vunit_run_de25_std_test.py de25_std_lib.max6650_fan_control_tb.all -v)
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library vunit_lib;
    context vunit_lib.vunit_context;

entity max6650_fan_control_tb is
    generic (runner_cfg : string);
end entity max6650_fan_control_tb;

architecture sim of max6650_fan_control_tb is
    signal clock    : std_logic := '0';
    signal reset    : std_logic := '1';
    signal ktach_in : std_logic_vector(7 downto 0) := x"4E";     -- 1500 rpm

    signal config_readback, alarm_status, gpio_status : std_logic_vector(7 downto 0);
    signal reconfig_count : std_logic_vector(3 downto 0);
    signal config_ok, init_done, i2c_error : std_logic;
    signal tach0 : std_logic_vector(7 downto 0);
    signal sda_low, scl_low : std_logic;

    -- the bus: open drain, pulled up
    signal sda, scl : std_logic;
    signal slave_sda_low : std_logic := '0';

    -- the chip's registers
    type regs_t is array (0 to 255) of std_logic_vector(7 downto 0);
    signal regs : regs_t := (16#02# => x"0A", 16#0C# => x"1A", 16#14# => x"1F", others => x"00");

    -- every register write the chip saw, in order
    type log_t is array (0 to 63) of std_logic_vector(15 downto 0);
    signal wlog  : log_t;
    signal wlogn : natural := 0;
    signal alarm_reads : natural := 0;

    -- test controls
    signal stuck       : boolean := false;   -- Config writes lose bits 5:4
    signal set_alarm   : boolean := false;   -- latch a min-output alarm
    signal drop_to_full_on : boolean := false;  -- Config falls to 0x09 by itself
    signal start_mid_byte : boolean := true; -- begin transmitting, SDA low
begin
    test_runner_watchdog(runner, 200 ms);
    clock <= not clock after 10 ns;           -- 50 MHz

    sda <= '0' when sda_low = '1' or slave_sda_low = '1' else 'H';
    scl <= '0' when scl_low = '1' else 'H';

    dut : entity work.max6650_fan_control
        generic map(g_clock_hz => 50_000_000, g_scl_hz => 1_000_000, g_min_rpm => 1500,
                    g_poll_cycles => 2_000, g_status_polls => 3, g_por_cycles => 1_000)
        port map(clock => clock, reset => reset, ktach_in => ktach_in,
                 rpm_out => open, tach0_out => tach0, config_readback => config_readback,
                 config_ok => config_ok, alarm_status => alarm_status, gpio_status => gpio_status,
                 reconfig_count => reconfig_count, ktach_out => open, init_done => init_done,
                 i2c_error => i2c_error, sda_in => sda, sda_low => sda_low, scl_low => scl_low);

    ------------------------------------------------------------------------
    -- the MAX6650, at address 0x48: register pointer, write, read with
    -- master ACK/NACK; START and STOP anywhere
    ------------------------------------------------------------------------
    chip : process(clock)
        type mode_t is (idle, rx, ack, tx, master_ack, wait_stop);
        variable mode : mode_t := idle;
        variable sda_p, scl_p, sda_n, scl_n : std_logic := '1';
        variable bits, byte_no : natural := 0;
        variable shift : std_logic_vector(7 downto 0);
        variable rw : std_logic := '0';
        variable ptr : natural := 0;
        variable txb : std_logic_vector(7 downto 0);
        variable txi : integer := 7;
        variable first : boolean := true;
        variable value : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clock) then
            sda_n := to_X01(sda); scl_n := to_X01(scl);
            if first then
                first := false;
                if start_mid_byte then        -- left mid-read with a 0 bit out
                    mode := tx; txb := x"00"; txi := 7; slave_sda_low <= '1';
                end if;
            end if;
            if set_alarm then
                regs(16#10#) <= x"02";
            end if;
            if drop_to_full_on then
                regs(16#02#) <= x"09";
            end if;
            if scl_n = '1' and scl_p = '1' and sda_p = '1' and sda_n = '0' and mode /= tx then
                mode := rx; bits := 0; byte_no := 0; slave_sda_low <= '0';        -- START
            elsif scl_n = '1' and scl_p = '1' and sda_p = '0' and sda_n = '1' and mode /= tx then
                mode := idle; slave_sda_low <= '0';                               -- STOP
            elsif scl_p = '0' and scl_n = '1' then                                -- SCL rises
                if mode = rx then
                    shift := shift(6 downto 0) & sda_n; bits := bits + 1;
                elsif mode = master_ack then
                    if sda_n = '1' then mode := wait_stop; end if;               -- NACK
                end if;
            elsif scl_p = '1' and scl_n = '0' then                                -- SCL falls
                case mode is
                    when rx =>
                        if bits = 8 then
                            bits := 0;
                            if byte_no = 0 then
                                rw := shift(0);
                                if shift(7 downto 1) = "1001000" then
                                    slave_sda_low <= '1'; mode := ack;
                                else
                                    mode := wait_stop;
                                end if;
                            elsif byte_no = 1 then
                                ptr := to_integer(unsigned(shift));
                                slave_sda_low <= '1'; mode := ack;
                            else
                                value := shift;
                                if ptr = 16#02# and stuck then
                                    value(5 downto 4) := "00";
                                end if;
                                regs(ptr) <= value;
                                wlog(wlogn) <= std_logic_vector(to_unsigned(ptr, 8)) & shift;
                                wlogn <= wlogn + 1;
                                slave_sda_low <= '1'; mode := ack;
                            end if;
                        end if;
                    when ack =>
                        slave_sda_low <= '0';
                        if byte_no = 0 and rw = '1' then
                            txb := regs(ptr); txi := 7; mode := tx;
                            if ptr = 16#10# then             -- reading clears the alarms
                                regs(16#10#) <= x"00"; alarm_reads <= alarm_reads + 1;
                            end if;
                            slave_sda_low <= not txb(7);
                        else
                            mode := rx;
                        end if;
                        byte_no := byte_no + 1;
                    when tx =>
                        if txi = 0 then
                            slave_sda_low <= '0'; mode := master_ack;
                        else
                            txi := txi - 1; slave_sda_low <= not txb(txi);
                        end if;
                    when master_ack =>                       -- ACK: another byte
                        txi := 7; mode := tx; slave_sda_low <= not txb(7);
                    when others => null;
                end case;
            end if;
            sda_p := sda_n; scl_p := scl_n;
        end if;
    end process;

    ------------------------------------------------------------------------
    test : process
        procedure wait_until(cond : boolean; what : string) is
        begin
            if not cond then
                wait until cond for 20 ms;
            end if;
            assert cond report "timeout: " & what severity failure;
        end procedure;
        variable n0, r0 : natural;
    begin
        test_runner_setup(runner, runner_cfg);
        wait for 100 ns;
        reset <= '0';

        -- 1. the bus recovery frees the chip, then the setup, in order
        wait until init_done = '1' for 20 ms;
        assert init_done = '1' and i2c_error = '0' report "no setup (bus not recovered?)" severity failure;
        wait for 1 us;
        assert wlogn >= 4 report "setup writes: " & integer'image(wlogn) severity failure;
        assert wlog(0) = x"1601" and wlog(1) = x"080F" and wlog(2) = x"04F5" and wlog(3) = x"0229"
            report "setup order: " & to_hstring(wlog(0)) & " " & to_hstring(wlog(1)) & " "
                   & to_hstring(wlog(2)) & " " & to_hstring(wlog(3)) severity failure;
        assert config_ok = '1' and config_readback = x"29" report "config readback " & to_hstring(config_readback) & ", chip " & to_hstring(regs(2)) severity failure;
        wait until wlogn >= 5 for 1 ms;
        assert wlog(4) = x"004E" report "Speed after the setup: " & to_hstring(wlog(4)) severity failure;

        -- 2. status reads: GPIO Status, a latched alarm read (and so cleared)
        set_alarm <= true; wait for 1 us; set_alarm <= false;
        wait until alarm_status = x"02" for 20 ms;
        assert alarm_status = x"02" report "alarm status: " & to_hstring(alarm_status) severity failure;
        wait until gpio_status = x"1F" for 1 ms;          -- read right after it
        assert gpio_status = x"1F" report "gpio status: " & to_hstring(gpio_status) severity failure;
        assert regs(16#10#) = x"00" report "alarm not cleared by the read" severity failure;
        wait until alarm_status = x"00" for 20 ms;
        assert alarm_status = x"00" report "alarm read again" severity failure;
        assert tach0 = x"1A" report "tach poll" severity failure;

        -- 3. the chip drops to full-on and will not take 0x29 for a while
        stuck <= true;
        drop_to_full_on <= true; wait for 1 us; drop_to_full_on <= false;
        wait until config_ok = '0' for 20 ms;
        assert config_ok = '0' and config_readback = x"09" report "full-on not seen" severity failure;
        wait until unsigned(reconfig_count) >= 2 for 50 ms;
        assert unsigned(reconfig_count) >= 2 report "no retries" severity failure;
        assert tach0 = x"1A" report "tach poll during the retries" severity failure;
        stuck <= false;
        wait until config_ok = '1' for 20 ms;
        assert config_ok = '1' and config_readback = x"29" report "not recovered" severity failure;
        r0 := to_integer(unsigned(reconfig_count));
        wait for 10 ms;
        assert to_integer(unsigned(reconfig_count)) = r0 report "retrying a good chip" severity failure;
        for i in 0 to wlogn - 1 loop
            assert wlog(i) /= x"020A" report "Config 0x0A written" severity failure;
        end loop;

        -- 4. a new target goes to Speed
        n0 := wlogn;
        ktach_in <= x"1D";
        wait until wlogn > n0 for 5 ms;
        assert wlog(n0) = x"001D" report "Speed: " & to_hstring(wlog(n0)) severity failure;
        assert i2c_error = '0' report "i2c_error" severity failure;
        report "PASS";
        test_runner_cleanup(runner);
    end process;
end architecture sim;
