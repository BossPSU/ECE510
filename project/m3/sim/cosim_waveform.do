## =============================================================================
## cosim_waveform.do -- Generate M3 end-to-end cosim waveform for deliverable
## =============================================================================
##
## Sets up a wave window showing the four annotated regions the rubric
## asks for:
##   (A) host-side write transactions      -- ucie_wr_*
##   (B) host-side macro command issue     -- ucie_cmd_*
##   (C) internal compute activity         -- lane-0 pipeline_running, busy
##   (D) host-side read of the result      -- ucie_rd_*
##
## Then runs the simulation to completion and exports the wave window as
## PostScript via the underlying Tk canvas (the only portable image-export
## hook in QuestaSim 2021.3). A second pass (convert) produces the PNG
## the rubric asks for.
##
## USAGE (from project/m3/sim/):
##
##   # 1. Compile RTL + TBs into the work library
##   ./run_verification.sh tb_top              ;# or just bash run...
##
##   # 2. Generate wave + PostScript
##   vsim -gui -do cosim_waveform.do work.tb_top
##   # vsim auto-quits after writing cosim_waveform.ps
##
##   # 3. Convert PS -> PNG (ImageMagick; available on phobos)
##   convert -density 150 -rotate 90 cosim_waveform.ps cosim_waveform.png
##
##   # 4. Commit both artifacts
##   git add cosim_run.log cosim_waveform.png
##   git commit -m "M3: cosim log + annotated waveform"
##   git push
##
## If `convert` rotates the wrong way, drop -rotate or use -rotate -90.
## =============================================================================

# Log everything (the M3 graders may want to inspect signals after the fact;
# +acc was already on at vlog time so logging now is free).
log -r /*

# ------------------------------------------------------------------ wave panel
# Clear any saved wave-format leftovers.
quietly catch { delete wave * }

add wave -divider "Reset / Clock"
add wave -format Logic /tb_top/rst_n
add wave -format Logic /tb_top/clk

add wave -divider "(A) Host -> Chiplet : DMA writes (UCIe)"
add wave -format Logic            /tb_top/ucie_wr_valid
add wave -format Logic            /tb_top/ucie_wr_ready
add wave -radix hex               /tb_top/ucie_wr_data

add wave -divider "(B) Host -> Chiplet : macro command (UCIe)"
add wave -format Logic            /tb_top/ucie_cmd_valid
add wave -format Logic            /tb_top/ucie_cmd_ready
add wave -radix hex               /tb_top/ucie_cmd_data

add wave -divider "Chiplet status (host-visible)"
add wave -format Logic            /tb_top/ucie_busy
add wave -format Logic            /tb_top/ucie_irq

add wave -divider "(C) Internal : lane 0 compute"
add wave -format Logic /tb_top/dut/u_core/u_accel_top/gen_lane[0]/u_engine/pipeline_running
add wave -format Logic /tb_top/dut/u_core/u_accel_top/gen_lane[0]/u_engine/u_ctrl/busy

add wave -divider "(D) Chiplet -> Host : read responses (UCIe)"
add wave -format Logic            /tb_top/ucie_rd_req
add wave -radix hex               /tb_top/ucie_rd_addr
add wave -format Logic            /tb_top/ucie_rd_valid
add wave -radix hex               /tb_top/ucie_rd_data

# ------------------------------------------------------------------ run sim
run -all

# ------------------------------------------------------------------ annotate
# Place markers at four key events. We discover the times by walking the
# signal change history rather than hard-coding cycle counts (the TB does
# 4096+4096 writes so the absolute times shift with any TB tweak).
#
# searchlog returns the time of the next matching transition.
proc time_of_first_rise {sig} {
    set t [examine -time -now $sig]
    set hits [searchlog -value 1 -startposition 0 $sig]
    if {[llength $hits] > 0} { return [lindex $hits 0] }
    return $t
}

# Cursors (markers). The names appear in the wave header.
set t_first_write [time_of_first_rise /tb_top/ucie_wr_valid]
set t_macro_issue [time_of_first_rise /tb_top/ucie_cmd_valid]
set t_irq         [time_of_first_rise /tb_top/ucie_irq]
set t_first_read  [time_of_first_rise /tb_top/ucie_rd_valid]

catch { wave cursor add -time $t_first_write -name {A first host write} }
catch { wave cursor add -time $t_macro_issue -name {B macro issue}      }
catch { wave cursor add -time $t_irq         -name {C compute done/IRQ} }
catch { wave cursor add -time $t_first_read  -name {D first read resp}  }

# Zoom to fit the whole run.
wave zoom full

# ------------------------------------------------------------------ export PS
# Find the wave window's underlying Tk canvas and dump it to PostScript.
# This is portable across Questa versions because it uses Tk, not a vendor-
# specific PNG export.
proc dump_wave_postscript {filename} {
    # The wave window's canvas widget. Path varies slightly across Questa
    # versions; try the modern path first, then the older one.
    set candidates [list \
        ".wave.tree.canvas" \
        ".wave.pane.right.canvas" \
        ".wave.workarea.canvas" \
    ]
    foreach c $candidates {
        if {[winfo exists $c]} {
            $c postscript -file $filename \
                          -pagewidth 1600 \
                          -colormode color
            return $c
        }
    }
    return ""
}

set found [dump_wave_postscript "cosim_waveform.ps"]
if {$found ne ""} {
    puts ""
    puts "==================================================================="
    puts "  Wave window dumped to PostScript via Tk canvas: $found"
    puts "  -> cosim_waveform.ps"
    puts ""
    puts "  Convert to PNG with ImageMagick:"
    puts "    convert -density 150 cosim_waveform.ps cosim_waveform.png"
    puts ""
    puts "  Then commit:"
    puts "    git add cosim_run.log cosim_waveform.png"
    puts "==================================================================="
} else {
    puts ""
    puts "WARNING: could not find wave canvas widget."
    puts "Use File -> Export -> Image (PNG) manually from the Wave window."
}

# Quit (use -force so unsaved-state prompt doesn't block scripts).
quit -force
