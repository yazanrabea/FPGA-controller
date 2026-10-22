`timescale 1ns / 1ps
//==========================================================================
// link_ctrl
//
// Phase 5 runtime link: the register file of docs/link_register_map.md
// behind link_frame.sv (the frame parser/responder), backing 5 sig_cell +
// 5 cap_cell instances (the same test pairs as Phase 4's
// phase4_loopback_top.sv).
//
// Phase 7 round 2 refactor: the parser/responder moved to link_frame.sv
// (shared with phase7_link_top.sv); this file keeps only the Phase 5
// register file. The register map and the command behaviour are unchanged:
//   WRITE_REG to 0x0001 (RUN_CTRL) pulses run_set (bit0=1) / run_clear
//   (bit0=0); to 0x0002 (APPLY_CTRL) pulses apply_cmd; APPLY/RUN/STOP
//   commands pulse the same; STATUS/0x0001/0x0003 read back `run`; the cap
//   cells' status bytes are read live, never stored.
// Ports are PACKED 2-D (`[N][W]`), not unpacked arrays: Icarus 12 drives
// unpacked-array output ports as X (docs/issues.md). Indexing is the same
// (`sig_cfg_delay[k]` is cell k's 32-bit value).
//==========================================================================
module link_ctrl #(
    parameter int N_SIG = 5,
    parameter int N_CAP = 5,
    parameter int MAX_PAYLOAD = 128   // bytes; covers the whole 120 B capture region in one frame
) (
    input  logic clk,
    input  logic rst_n,

    // from uart_rx
    input  logic [7:0] rx_byte,
    input  logic       rx_byte_valid,

    // to uart_tx
    output logic [7:0] tx_byte,
    output logic       tx_send,
    input  logic       tx_busy,

    // run_ctrl
    output logic run_set,
    output logic run_clear,
    output logic apply_cmd,
    input  logic run,

    // sig_cell shadow config, one entry per cell
    output wire  [N_SIG-1:0][2:0]  sig_cfg_type,
    output wire  [N_SIG-1:0]       sig_cfg_idle_level,
    output wire  [N_SIG-1:0]       sig_cfg_msb_first,
    output wire  [N_SIG-1:0][31:0] sig_cfg_delay,
    output wire  [N_SIG-1:0][31:0] sig_cfg_param_a,
    output wire  [N_SIG-1:0][31:0] sig_cfg_param_b,
    output wire  [N_SIG-1:0][31:0] sig_cfg_cycles,
    output wire  [N_SIG-1:0][15:0] sig_cfg_data,
    output wire  [N_SIG-1:0][31:0] sig_cfg_bits,

    // cap_cell shadow config
    output wire  [N_CAP-1:0][1:0]  cap_cfg_mode,
    output wire  [N_CAP-1:0]       cap_cfg_msb_first,
    output wire  [N_CAP-1:0][31:0] cap_cfg_bits,

    // cap_cell live status/results (read-only from the link's point of view)
    input  logic [N_CAP-1:0]       cap_level_out,
    input  logic [N_CAP-1:0]       cap_period_valid,
    input  logic [N_CAP-1:0]       cap_done,
    input  logic [N_CAP-1:0][31:0] cap_edge_count,
    input  logic [N_CAP-1:0][31:0] cap_period_ticks,
    input  logic [N_CAP-1:0][31:0] cap_high_ticks,
    input  logic [N_CAP-1:0][15:0] cap_capture_reg
);

    localparam int SIG_BASE   = 16'h0010;
    localparam int SIG_STRIDE = 24;
    localparam int CAP_BASE   = 16'h0100;
    localparam int CAP_STRIDE = 24;
    localparam int REG_BYTES  = CAP_BASE + N_CAP * CAP_STRIDE;  // size of the backing array

    // ---- frame parser/responder ----
    logic        bus_we, bus_re;
    logic [15:0] bus_waddr, bus_raddr;
    logic [7:0]  bus_wdata, bus_rdata;
    logic        cmd_apply, cmd_run, cmd_stop;

    link_frame #(.MAX_PAYLOAD(MAX_PAYLOAD), .CAP_BASE(16'(CAP_BASE)), .STATUS_ADDR(16'h0003)) u_frame (
        .clk(clk), .rst_n(rst_n),
        .rx_byte(rx_byte), .rx_byte_valid(rx_byte_valid),
        .tx_byte(tx_byte), .tx_send(tx_send), .tx_busy(tx_busy),
        .bus_we(bus_we), .bus_waddr(bus_waddr), .bus_wdata(bus_wdata),
        .bus_re(bus_re), .bus_raddr(bus_raddr), .bus_rdata(bus_rdata),
        .cmd_apply(cmd_apply), .cmd_run(cmd_run), .cmd_stop(cmd_stop),
        .rx_overflow()   // not in the Phase 5 register map
    );

    // ---- the flat byte-addressable backing store for every WRITABLE field
    //      (global SCRATCH/RUN_CTRL/APPLY_CTRL, every sig_cell field, and
    //      every cap_cell's CTRL/BITS). Read-only cap_cell status/results
    //      bytes are never stored here -- reads to those addresses answer
    //      from the live cap_* inputs instead, so they never go stale.
    logic [7:0] regs [0:REG_BYTES-1];

    // ---- assemble each cell's cfg_* from the backing store ----
    genvar gi;
    generate
        for (gi = 0; gi < N_SIG; gi = gi + 1) begin : g_sig_wire
            localparam int B = SIG_BASE + SIG_STRIDE * gi;
            assign sig_cfg_type[gi]       = regs[B][2:0];
            assign sig_cfg_idle_level[gi] = regs[B][3];
            assign sig_cfg_msb_first[gi]  = regs[B][4];
            assign sig_cfg_delay[gi]      = {regs[B+4],  regs[B+3],  regs[B+2],  regs[B+1]};
            assign sig_cfg_param_a[gi]    = {regs[B+8],  regs[B+7],  regs[B+6],  regs[B+5]};
            assign sig_cfg_param_b[gi]    = {regs[B+12], regs[B+11], regs[B+10], regs[B+9]};
            assign sig_cfg_cycles[gi]     = {regs[B+16], regs[B+15], regs[B+14], regs[B+13]};
            assign sig_cfg_data[gi]       = {regs[B+18], regs[B+17]};
            assign sig_cfg_bits[gi]       = {regs[B+22], regs[B+21], regs[B+20], regs[B+19]};
        end
        for (gi = 0; gi < N_CAP; gi = gi + 1) begin : g_cap_wire
            localparam int B = CAP_BASE + CAP_STRIDE * gi;
            assign cap_cfg_mode[gi]      = regs[B][1:0];
            assign cap_cfg_msb_first[gi] = regs[B][2];
            assign cap_cfg_bits[gi]      = {regs[B+4], regs[B+3], regs[B+2], regs[B+1]};
        end
    endgenerate

    // ---- read, with the read-only intercepts ----
    function automatic logic [7:0] read_byte(logic [15:0] addr);
        int k;
        int off;
        logic [31:0] edges, period, high;   // cell k's values, copied out first: Icarus 12
        logic [15:0] capt;                  // can't do x[k][7:0] on a packed 2-D array
        if (addr == 16'h0001) return {7'b0, run};
        if (addr == 16'h0002) return 8'h00;
        if (addr == 16'h0003) return {7'b0, run};
        if (addr >= CAP_BASE && addr < CAP_BASE + N_CAP * CAP_STRIDE) begin
            k      = (addr - CAP_BASE) / CAP_STRIDE;
            off    = (addr - CAP_BASE) % CAP_STRIDE;
            edges  = cap_edge_count[k];
            period = cap_period_ticks[k];
            high   = cap_high_ticks[k];
            capt   = cap_capture_reg[k];
            case (off)
                5:  return {5'b0, cap_done[k], cap_period_valid[k], cap_level_out[k]};
                6:  return edges[7:0];
                7:  return edges[15:8];
                8:  return edges[23:16];
                9:  return edges[31:24];
                10: return period[7:0];
                11: return period[15:8];
                12: return period[23:16];
                13: return period[31:24];
                14: return high[7:0];
                15: return high[15:8];
                16: return high[23:16];
                17: return high[31:24];
                18: return capt[7:0];
                19: return capt[15:8];
                default: return (addr < REG_BYTES) ? regs[addr] : 8'h00;
            endcase
        end
        return (addr < REG_BYTES) ? regs[addr] : 8'h00;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run_set   <= 1'b0;
            run_clear <= 1'b0;
            apply_cmd <= 1'b0;
            bus_rdata <= '0;
            for (int i = 0; i < REG_BYTES; i++) regs[i] <= 8'h00;
        end else begin
            run_set   <= cmd_run;
            run_clear <= cmd_stop;
            apply_cmd <= cmd_apply;
            if (bus_re) bus_rdata <= read_byte(bus_raddr);   // 1-tick read latency
            if (bus_we) begin
                if (bus_waddr < REG_BYTES) regs[bus_waddr] <= bus_wdata;
                if (bus_waddr == 16'h0001) begin
                    run_set   <= bus_wdata[0];
                    run_clear <= !bus_wdata[0];
                end
                if (bus_waddr == 16'h0002) apply_cmd <= 1'b1;
            end
        end
    end

endmodule
