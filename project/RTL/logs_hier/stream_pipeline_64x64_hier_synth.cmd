# Cadence Genus(TM) Synthesis Solution, Version 21.12-s068_1, built Mar  4 2022 14:12:46

# Date: Sat May 30 17:17:58 2026
# Host: phobos.ece.pdx.edu (x86_64 w/Linux 5.14.0-611.54.1.el9_7.x86_64) (1core*32cpus*32physical cpus*Intel Xeon Processor (Cascadelake) 16384KB)
# OS:   Rocky Linux release 9.7 (Blue Onyx)

source run_genus_hier.do
write_hdl > out_sweep/stream_pipeline_64x64_hier/stream_pipeline.v
write_sdc > out_sweep/stream_pipeline_64x64_hier/stream_pipeline.sdc
report_power                  > out_sweep/stream_pipeline_64x64_hier/reports/power.rpt
report_gates                  > out_sweep/stream_pipeline_64x64_hier/reports/gates.rpt
report_qor                    > out_sweep/stream_pipeline_64x64_hier/reports/qor.rpt
report_messages               > out_sweep/stream_pipeline_64x64_hier/reports/messages.rpt
report_hierarchy              > out_sweep/stream_pipeline_64x64_hier/reports/hierarchy.rpt
catch {
    report_timing -from [all_registers -edge_triggered] \
                  -to   [all_registers -edge_triggered] \
                  -max_paths 20 > out_sweep/stream_pipeline_64x64_hier/reports/timing_reg2reg.rpt
}
head -80 out_sweep/stream_pipeline_64x64_hier/reports/timing.rpt
