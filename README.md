# CRC-16 Serial Packet Checker — Complete Cadence ASIC Flow

[![HDL](https://img.shields.io/badge/HDL-Verilog--2001-blue.svg)]()
[![Synthesis](https://img.shields.io/badge/Synthesis-Cadence%20Genus%2021.14-red.svg)]()
[![PnR](https://img.shields.io/badge/P%26R-Cadence%20Innovus%2021.15-orange.svg)]()
[![Formal](https://img.shields.io/badge/Formal%20LEC-Cadence%20Conformal%2021.10-green.svg)]()
[![Coverage](https://img.shields.io/badge/Toggle%20Coverage-100%25-brightgreen.svg)]()
[![Signoff](https://img.shields.io/badge/Signoff-Clean%20(WNS%200.00%20%7C%20TNS%200.00)-success.svg)]()

Industrial digital ASIC implementation of a high-performance **CRC-16/CCITT serial packet checker** ($x^{16} + x^{12} + x^5 + 1$). The design is taken through the full Cadence digital flow: RTL design, self-checking verification with 100% toggle coverage, logic synthesis, formal equivalence checking (LEC), and physical design to GDSII.

---

## ⚙️ Architecture & Features

* **CRC Convention:** CRC-16/CCITT-FALSE (`0x1021`), initial state `0xFFFF`, MSB-first, unreflected. Verified against reference string `"123456789"` $\rightarrow$ `0x29B1`.
* **Zero Redundant State Encoding:** The `busy` flag acts as the sole state bit, ensuring identical flop sets between RTL and synthesized gate netlists.
* **Stable Holding Outputs:** `crc_result` and `match` remain stable across idle and stall periods until the subsequent packet finishes.

---

## 🧪 Verification & Coverage Signoff

* **Simulation:** SimVision / NCLaunch self-checking testbench with an independent LFSR-based Galois reference model.
* **130+ Packets Tested:** Random packet lengths (1–40, 64, 72, 128, 256 bits), bus noise during stalls, corrupted expected CRC check vectors (all 16 single-bit flips and full inversions), and mid-packet resets.
* **100% Toggle Coverage:** Signed off in Cadence IMC across all internal registers and buses (`crc_reg`, `exp_reg`, `crc_result`, `crc_next`).

---

## 📊 Logic Synthesis (Cadence Genus 21.14)

Mapped to standard-cell `slow` library at 100 MHz (10 ns clock, 0.15 pF pin load).

| Metric | Vectorless Synthesis | VCD-Annotated Simulation | Unit |
| :--- | :---: | :---: | :---: |
| **Total Standard Cells** | 193 | 193 | cells |
| **Total Cell Area** | 1497.905 | 1497.905 | $\mu\text{m}^2$ |
| **Sequential Logic Share** | 55.4% (51 DFFs) | 55.4% (51 DFFs) | — |
| **Combinational Logic Share** | 43.9% (137 gates) | 43.9% (137 gates) | — |
| **Inverters** | 0.8% (5 gates) | 0.8% (5 gates) | — |
| **Setup Slack (Worst Path)** | **+7.346** | **+7.346** | ns |
| **Total Dynamic Power** | 143.8 | **114.1 (-21%)** | $\mu\text{W}$ |

---

## 🔒 Formal Equivalence Checking (Cadence Conformal LEC 21.10)

* **Key Points Mapped:** 92 total (22 Inputs, 19 Outputs, 51 DFFs).
* **Compare Points:** 70 (19 POs + 51 DFFs).
* **Status:** **PASS** (0 non-equivalent, 0 unmapped).

---

## 📐 Physical Design Signoff (Cadence Innovus 21.15)

Full physical flow: Floorplan $\rightarrow$ Power Grid $\rightarrow$ Cell Placement $\rightarrow$ CCOPT Clock Tree Synthesis $\rightarrow$ NanoRoute (M1–M9) $\rightarrow$ SPEF Extraction $\rightarrow$ GDSII Streamout.

| Signoff Check | Pre-CTS Slack | Post-CTS Slack | Violations |
| :--- | :---: | :---: | :---: |
| **Setup Timing (Late)** | +7.115 ns | **+7.115 ns** | 0 |
| **Hold Timing (Early)** | +0.288 ns | **+0.288 ns** | 0 |
| **WNS / TNS** | 0.000 ns | **0.000 ns** | 0 |
| **DRC / LVS** | 0 | **0** | Clean |

---

## 🔬 Hardware Study: Sparse XOR Network

* **Logic Depth:** The feedback XOR is 2 gates deep (`NAND2XL` + `OAI21X1` $\rightarrow$ `CLKINVX1`), taking only **0.258 ns** of the 2.715 ns worst-case path ($<10\%$).
* **Fanout:** Since `0x1021` only taps bits 12, 5, and 0, the feedback line drives only 9 physical pins, avoiding buffer trees.
* **Parallel Scaling:** Expanding to 32 bits/clock increases combinational XOR cells from 5 to 332 ($66\times$ area increase for $32\times$ throughput) while flip-flops remain fixed at 16.

---

## 📁 Repository Structure

```text
├── rtl/
│   └── crc.v                  # Synthesizable CRC-16 checker RTL
├── tb/
│   └── crc_tb.v               # Self-checking testbench
├── syn/
│   └── crc_constraints.sdc    # SDC 2.0 timing constraints
└── README.md
cd ~
mkdir -p crc16-cadence-asic-flow/{rtl,tb,syn,docs}
cd crc16-cadence-asic-flow

# 1. Write rtl/crc.v
cat << 'EOF' > rtl/crc.v
`timescale 1ns/1ps

module crc16_checker (
    input  wire        clk,
    input  wire        rst_n,          // active-low synchronous reset
    input  wire        start,          // pulse: begin new packet (idle only)
    input  wire        bit_valid,      // data_bit is valid this cycle
    input  wire        data_bit,       // serial data, MSB-first
    input  wire        last_bit,       // this accepted bit is the last
    input  wire [15:0] expected_crc,   // captured on start
    output reg         busy,           // 1 while processing a packet
    output reg  [15:0] crc_result,     // final CRC after last_bit
    output reg         match,          // crc_result == expected_crc
    output reg         done            // 1-cycle pulse after last_bit
);

    reg [15:0] crc_reg;
    reg [15:0] exp_reg;

    wire        feedback;
    wire [15:0] crc_next;
    wire        accept;

    assign feedback = crc_reg[15] ^ data_bit;
    assign crc_next = {crc_reg[14:0], 1'b0} ^ (feedback ? 16'h1021 : 16'h0000);
    assign accept   = busy & bit_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            busy       <= 1'b0;
            crc_reg    <= 16'hFFFF;
            exp_reg    <= 16'h0000;
            crc_result <= 16'h0000;
            match      <= 1'b0;
            done       <= 1'b0;
        end
        else begin
            done <= accept & last_bit;

            if (!busy) begin
                if (start) begin
                    busy    <= 1'b1;
                    crc_reg <= 16'hFFFF;
                    exp_reg <= expected_crc;
                end
            end
            else if (accept) begin
                if (last_bit) begin
                    crc_result <= crc_next;
                    match      <= (crc_next == exp_reg);
                    busy       <= 1'b0;
                    crc_reg    <= 16'hFFFF;
                end
                else begin
                    crc_reg <= crc_next;
                end
            end
        end
    end

endmodule
