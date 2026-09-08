# qsys-script: drop the iopll_0 clock generator from the vendored
# hps_subsystem.qsys (datacenter_peak_shaving/fpga/agilex/de25/ip/hps/) -
# this project's fabric runs on the board's 50 MHz oscillator directly, so
# the HPS subsystem doesn't need its own PLL.  Bridges are left exactly as
# vendored (H2F/F2SDRAM/F2H off, LWH2F on) - see hps/README.md.
#
#   qsys-script --package-version=25.1 --new-quartus-project=_t \
#       --script=trim_hps_subsystem.tcl --search-path='ip/hps_subsystem,$'
#   rm -f *.qpf *.qsf ; rm -rf _t*
#
# Re-run only if hps_subsystem.qsys is re-vendored from an upstream source
# that still has iopll_0 in it.

load_system hps_subsystem.qsys
catch {remove_instance iopll_0}
foreach f {iopll_0_locked iopll_0_refclk iopll_0_reset main_clock modulator_clock} {
    catch {remove_interface $f}
}
save_system hps_subsystem.qsys
