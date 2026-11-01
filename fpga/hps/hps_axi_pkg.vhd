------------------------------------------------------------------------
-- hps_axi_pkg - the HPS's AXI buses as records, one per direction:
-- *_m2s from the manager (the side that starts transactions) to the
-- subordinate, *_s2m back. hps.vhd wraps the generated hps_subsystem with
-- these instead of the hundreds of separate signals Platform Designer
-- exports.
--
--   lwhps2fpga (LWH2F)  HPS manages, AXI4 32 bit:  t_lwh2f_m2s / t_lwh2f_s2m
--   f2sdram             fabric manages, AXI4 256 bit, straight into the
--                       DDR (not cache coherent)
--   fpga2hps (F2H)      fabric manages, ACE5-Lite 256 bit, through the
--                       cache coherent interconnect (CCU)
--
-- F2SDRAM and F2H share t_axi256_m2s / t_axi256_s2m, so one fabric manager
-- can drive either. The ACE5-Lite fields (domain, snoop, stash, atop) are
-- left out on F2SDRAM. Widths are those hps_subsystem was generated with
-- (fpga/hps/README.md).
------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;

package hps_axi_pkg is

    -- lwhps2fpga: 4 bit ids, 29 bit addresses, 32 bit data
    type t_lwh2f_m2s is record
        awid    : std_logic_vector(3 downto 0);
        awaddr  : std_logic_vector(28 downto 0);
        awlen   : std_logic_vector(7 downto 0);
        awsize  : std_logic_vector(2 downto 0);
        awburst : std_logic_vector(1 downto 0);
        awlock  : std_logic;
        awcache : std_logic_vector(3 downto 0);
        awprot  : std_logic_vector(2 downto 0);
        awvalid : std_logic;
        wdata   : std_logic_vector(31 downto 0);
        wstrb   : std_logic_vector(3 downto 0);
        wlast   : std_logic;
        wvalid  : std_logic;
        bready  : std_logic;
        arid    : std_logic_vector(3 downto 0);
        araddr  : std_logic_vector(28 downto 0);
        arlen   : std_logic_vector(7 downto 0);
        arsize  : std_logic_vector(2 downto 0);
        arburst : std_logic_vector(1 downto 0);
        arlock  : std_logic;
        arcache : std_logic_vector(3 downto 0);
        arprot  : std_logic_vector(2 downto 0);
        arvalid : std_logic;
        rready  : std_logic;
    end record;

    type t_lwh2f_s2m is record
        awready : std_logic;
        wready  : std_logic;
        bid     : std_logic_vector(3 downto 0);
        bresp   : std_logic_vector(1 downto 0);
        bvalid  : std_logic;
        arready : std_logic;
        rid     : std_logic_vector(3 downto 0);
        rdata   : std_logic_vector(31 downto 0);
        rresp   : std_logic_vector(1 downto 0);
        rlast   : std_logic;
        rvalid  : std_logic;
    end record;

    -- f2sdram and fpga2hps: 5 bit ids, 32 bit addresses, 256 bit data,
    -- 8 bit user fields
    type t_axi256_m2s is record
        awid          : std_logic_vector(4 downto 0);
        awaddr        : std_logic_vector(31 downto 0);
        awlen         : std_logic_vector(7 downto 0);
        awsize        : std_logic_vector(2 downto 0);
        awburst       : std_logic_vector(1 downto 0);
        awlock        : std_logic;
        awcache       : std_logic_vector(3 downto 0);
        awprot        : std_logic_vector(2 downto 0);
        awqos         : std_logic_vector(3 downto 0);
        awregion      : std_logic_vector(3 downto 0);
        awuser        : std_logic_vector(7 downto 0);
        awvalid       : std_logic;
        -- ACE5-Lite (fpga2hps only)
        awdomain      : std_logic_vector(1 downto 0);
        awsnoop       : std_logic_vector(3 downto 0);
        awstashnid    : std_logic_vector(10 downto 0);
        awstashniden  : std_logic;
        awstashlpid   : std_logic_vector(4 downto 0);
        awstashlpiden : std_logic;
        awatop        : std_logic_vector(5 downto 0);

        wdata         : std_logic_vector(255 downto 0);
        wstrb         : std_logic_vector(31 downto 0);
        wlast         : std_logic;
        wuser         : std_logic_vector(7 downto 0);
        wvalid        : std_logic;

        bready        : std_logic;

        arid          : std_logic_vector(4 downto 0);
        araddr        : std_logic_vector(31 downto 0);
        arlen         : std_logic_vector(7 downto 0);
        arsize        : std_logic_vector(2 downto 0);
        arburst       : std_logic_vector(1 downto 0);
        arlock        : std_logic;
        arcache       : std_logic_vector(3 downto 0);
        arprot        : std_logic_vector(2 downto 0);
        arqos         : std_logic_vector(3 downto 0);
        arregion      : std_logic_vector(3 downto 0);
        aruser        : std_logic_vector(7 downto 0);
        arvalid       : std_logic;
        -- ACE5-Lite (fpga2hps only)
        ardomain      : std_logic_vector(1 downto 0);
        arsnoop       : std_logic_vector(3 downto 0);

        rready        : std_logic;
    end record;

    type t_axi256_s2m is record
        awready : std_logic;
        wready  : std_logic;
        bid     : std_logic_vector(4 downto 0);
        bresp   : std_logic_vector(1 downto 0);
        buser   : std_logic_vector(7 downto 0);
        bvalid  : std_logic;
        arready : std_logic;
        rid     : std_logic_vector(4 downto 0);
        rdata   : std_logic_vector(255 downto 0);
        rresp   : std_logic_vector(1 downto 0);
        rlast   : std_logic;
        ruser   : std_logic_vector(7 downto 0);
        rvalid  : std_logic;
    end record;

    -- nothing going on: no valid, no ready; the rest 0
    constant c_lwh2f_s2m_idle : t_lwh2f_s2m := (
        bid => (others => '0'), bresp => (others => '0'), rid => (others => '0'),
        rdata => (others => '0'), rresp => (others => '0'), others => '0');

    -- an idle subordinate: no ready, no valid
    constant c_axi256_s2m_idle : t_axi256_s2m := (
        bid => (others => '0'), bresp => (others => '0'), buser => (others => '0'),
        rid => (others => '0'), rdata => (others => '0'), rresp => (others => '0'),
        ruser => (others => '0'), others => '0');

    -- An idle manager: no valid, but bready and rready high (it would take
    -- any response). Not only good manners: the HPS has a ready-latency
    -- FIFO behind each of these buses, and with rready tied low it is never
    -- read, synthesis removes it, and the hard block's RDATA ends up
    -- unconnected - which Quartus refuses (fpga/hps/README.md).
    -- The manager side's defaults for 32-byte beats: INCR bursts, size
    -- 256 bit, AxCACHE 0011 (bufferable, modifiable), ACE5-Lite domain "00"
    -- (non-shareable: the CCU does not snoop the CPU caches). Coherent
    -- F2H traffic needs a shareable domain and cacheable AxCACHE; which
    -- exact values the Agilex 5 CCU wants is to be measured
    -- (docs/plan_scope.md, phase 2) before anything relies on it.
    constant c_axi256_m2s_idle : t_axi256_m2s := (
        awid => (others => '0'), awaddr => (others => '0'), awlen => (others => '0'),
        awsize => "101", awburst => "01", awlock => '0', awcache => "0011",
        awprot => "000", awqos => (others => '0'), awregion => (others => '0'),
        awuser => (others => '0'), awvalid => '0',
        awdomain => "00", awsnoop => (others => '0'), awstashnid => (others => '0'),
        awstashniden => '0', awstashlpid => (others => '0'), awstashlpiden => '0',
        awatop => (others => '0'),
        wdata => (others => '0'), wstrb => (others => '0'), wlast => '0',
        wuser => (others => '0'), wvalid => '0',
        bready => '1',
        arid => (others => '0'), araddr => (others => '0'), arlen => (others => '0'),
        arsize => "101", arburst => "01", arlock => '0', arcache => "0011",
        arprot => "000", arqos => (others => '0'), arregion => (others => '0'),
        aruser => (others => '0'), arvalid => '0',
        ardomain => "00", arsnoop => (others => '0'),
        rready => '1');

    -- the XOR of every bit a subordinate returns: logic that uses all of a
    -- bus's outputs. Quartus refuses an enabled F2SDRAM / F2H bus whose
    -- outputs drive nothing ("not legally connected"); until a real manager
    -- uses them, de25_soc_top.vhd keeps them in register 27 this way.
    function parity(s : t_axi256_s2m) return std_logic;

end package hps_axi_pkg;

package body hps_axi_pkg is

    function parity(s : t_axi256_s2m) return std_logic is
        constant all_bits : std_logic_vector :=
            s.awready & s.wready & s.bid & s.bresp & s.buser & s.bvalid
            & s.arready & s.rid & s.rdata & s.rresp & s.rlast & s.ruser & s.rvalid;
        variable p : std_logic := '0';
    begin
        for i in all_bits'range loop
            p := p xor all_bits(i);
        end loop;
        return p;
    end function;

end package body hps_axi_pkg;
