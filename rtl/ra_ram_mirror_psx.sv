// RetroAchievements RAM Mirror for PSX — Option C: Selective Address Reading
//
// Each VBlank, reads a list of specific addresses from DDRAM (written by ARM),
// fetches the byte values from SDRAM (Main RAM via CH4), and writes them back
// to DDRAM for the ARM to read via rcheevos.
//
// PSX Main RAM: 2MB (or 8MB with expansion) in SDRAM at address 0.
// All RA addresses are byte addresses into Main RAM (0x000000-0x1FFFFF / 0x7FFFFF).
//
// DDRAM Layout (at DDRAM_BASE, ARM phys 0x3D000000):
//   [0x00000] Header:   magic(32) + 0(8) + flags(8) + 0(16)
//   [0x00008] Frame:    frame_counter(32) + 0(32)
//   [0x00010] Debug1:   {ver(8), dispatch_cnt(8), first_dout(16), timeout_cnt(16), ok_cnt(16)}
//   [0x00018] Debug2:   {first_addr(16), 0(16), 0(16), max_timeout(16)}
//
//   [0x40000] AddrReq:  addr_count(32) + request_id(32)       (ARM → FPGA)
//   [0x40008] Addrs:    addr[0](32) + addr[1](32), ...        (2 per 64-bit word)
//
//   [0x48000] ValResp:  response_id(32) + response_frame(32)  (FPGA → ARM)
//   [0x48008] Values:   val[0..7](8b each), val[8..15], ...   (8 per 64-bit word)

module ra_ram_mirror_psx #(
parameter [28:0] DDRAM_BASE = 29'h07A00000,  // ARM phys 0x3D000000 >> 3
parameter BYPASS_SDRAM = 0   // Debug: skip SDRAM reads, write addr-based pattern
)(
input             clk,           // clk_1x (~33 MHz)
input             reset,
input             vblank,

// SDRAM CH4 read interface (Main RAM)
output reg [26:0] ch4_addr,
output reg        ch4_req,
input      [31:0] ch4_dout,
input             ch4_ready,

// DDRAM write interface (toggle req/ack)
output reg [28:0] ddram_wr_addr,
output reg [63:0] ddram_wr_din,
output reg  [7:0] ddram_wr_be,
output reg        ddram_wr_req,
input             ddram_wr_ack,

// DDRAM read interface (toggle req/ack)
output reg [28:0] ddram_rd_addr,
output reg        ddram_rd_req,
input             ddram_rd_ack,
input      [63:0] ddram_rd_dout,

// Status
output reg        active,
output reg [31:0] dbg_frame_counter
);

// ======================================================================
// Constants
// ======================================================================
localparam [28:0] ADDRLIST_BASE = DDRAM_BASE + 29'h8000;  // byte offset 0x40000 / 8
localparam [28:0] VALCACHE_BASE = DDRAM_BASE + 29'h9000;  // byte offset 0x48000 / 8
localparam [12:0] MAX_ADDRS     = 13'd4096;

// Realtime query mailbox (Option C "on steroids")
localparam [28:0] QUERY_CTRL_ADDR = DDRAM_BASE + 29'hA000;  // byte offset 0x50000 / 8
localparam [28:0] QUERY_REQ_BASE  = DDRAM_BASE + 29'hA001;  // byte offset 0x50008 / 8
localparam [28:0] QUERY_RESP_BASE = DDRAM_BASE + 29'hA011;  // byte offset 0x50088 / 8
localparam [3:0]  MAX_RT_QUERIES  = 4'd16;

// FPGA version stamp (ARM checks this to verify bitstream)
localparam [7:0] FPGA_VERSION   = 8'h02;  // PSX v2 (realtime queries)

// ======================================================================
// Clock domain crossing synchronizers (DDRAM arbiter is on clk_2x)
// ======================================================================
reg dwr_ack_s1, dwr_ack_s2;
reg drd_ack_s1, drd_ack_s2;
always @(posedge clk) begin
dwr_ack_s1 <= ddram_wr_ack; dwr_ack_s2 <= dwr_ack_s1;
drd_ack_s1 <= ddram_rd_ack; drd_ack_s2 <= drd_ack_s1;
end

// ======================================================================
// VBlank edge detection
// ======================================================================
reg vblank_prev;
wire vblank_rising = vblank & ~vblank_prev;
always @(posedge clk) vblank_prev <= vblank;

// Sticky vblank flag — captures edge even when busy in query states
reg vblank_pending;
always @(posedge clk) begin
if (reset)
vblank_pending <= 1'b0;
else if (vblank_rising)
vblank_pending <= 1'b1;
else if (state == S_IDLE && vblank_pending)
vblank_pending <= 1'b0;
end

// ======================================================================
// State machine
// ======================================================================
localparam S_IDLE        = 5'd0;
localparam S_DD_WR_WAIT  = 5'd1;
localparam S_DD_RD_WAIT  = 5'd2;
localparam S_READ_HDR    = 5'd3;
localparam S_PARSE_HDR   = 5'd4;
localparam S_READ_PAIR   = 5'd5;
localparam S_PARSE_ADDR  = 5'd6;
localparam S_DISPATCH    = 5'd7;
localparam S_FETCH_RAM   = 5'd8;
localparam S_RAM_WAIT    = 5'd9;
localparam S_STORE_VAL   = 5'd10;
localparam S_FLUSH_BUF   = 5'd11;
localparam S_WRITE_RESP  = 5'd12;
localparam S_WR_HDR0     = 5'd13;
localparam S_WR_HDR1     = 5'd14;
localparam S_WR_DBG      = 5'd15;
localparam S_WR_DBG2     = 5'd16;
// Realtime query states
localparam S_QRY_PARSE   = 5'd17;
localparam S_QRY_RD_REQ  = 5'd18;
localparam S_QRY_FETCH   = 5'd19;
localparam S_QRY_WAIT    = 5'd20;
localparam S_QRY_WR_RESP = 5'd21;
localparam S_QRY_WR_CTRL = 5'd22;

reg [4:0]  state;
reg [4:0]  return_state;

reg [31:0] frame_counter;
always @(posedge clk) dbg_frame_counter <= frame_counter;

reg [63:0] rd_data;
reg [31:0] req_count;
reg [31:0] req_id;
reg [12:0] addr_idx;
reg [63:0] addr_word;
reg [31:0] cur_addr;
reg [63:0] collect_buf;
reg  [3:0] collect_cnt;
reg [12:0] val_word_idx;

reg        ch4_phase;
reg [15:0] timeout;
reg  [7:0] fetch_byte;
reg        ch4_req_pending;

// Realtime query registers
reg  [7:0] qry_request_seq;
reg  [7:0] qry_last_seen_seq;
reg  [7:0] qry_num;
reg  [3:0] qry_idx;
reg [31:0] qry_addr;
reg  [7:0] qry_num_bytes;
reg [31:0] qry_value;
reg  [2:0] qry_byte_idx;
reg        qry_ch4_phase;

// Rate limiter for query mailbox polling (prevents continuous DDRAM contention)
reg [9:0]  qry_poll_timer;

// Debug counters
reg [15:0] dbg_ok_cnt;
reg [15:0] dbg_timeout_cnt;
reg [15:0] dbg_first_dout;
reg        dbg_first_cap;
reg [15:0] dbg_max_timeout;
reg  [7:0] dbg_dispatch_cnt;
reg [15:0] dbg_first_addr;

// DDRAM wait timeout counter (prevents permanent stall if arbiter doesn't respond)
reg [19:0] ddram_wait_timeout;

// ======================================================================
// Main state machine
// ======================================================================
always @(posedge clk) begin
if (reset) begin
state           <= S_IDLE;
active          <= 1'b0;
frame_counter   <= 32'd0;
ch4_req         <= 1'b0;
ch4_req_pending <= 1'b0;
ddram_wr_req    <= dwr_ack_s2;
ddram_rd_req    <= drd_ack_s2;
qry_last_seen_seq <= 8'd0;
qry_poll_timer  <= 10'd0;
end
else begin
// Deassert ch4_req after one cycle (pulse)
if (ch4_req) ch4_req <= 1'b0;

case (state)

// =============================================================
// IDLE: Wait for VBlank (sticky flag) or poll query mailbox
// =============================================================
S_IDLE: begin
active <= 1'b0;
if (vblank_pending) begin
active <= 1'b1;
qry_poll_timer   <= 10'd0;
dbg_ok_cnt       <= 16'd0;
dbg_timeout_cnt  <= 16'd0;
dbg_first_cap    <= 1'b0;
dbg_first_dout   <= 16'd0;
dbg_max_timeout  <= 16'd0;
dbg_dispatch_cnt <= 8'd0;
dbg_first_addr   <= 16'd0;
// Write header with busy=1
ddram_wr_addr <= DDRAM_BASE;
ddram_wr_din  <= {16'd0, 8'h01, 8'd0, 32'h52414348};
ddram_wr_be   <= 8'hFF;
ddram_wr_req  <= ~ddram_wr_req;
return_state  <= S_READ_HDR;
state         <= S_DD_WR_WAIT;
end
else if (qry_poll_timer < 10'd1000) begin
// Rate limit: wait ~30µs between query polls to avoid
// continuous DDRAM contention that stalls the PSX core
qry_poll_timer <= qry_poll_timer + 10'd1;
end
else begin
// Poll realtime query mailbox (~33K polls/sec instead of ~2M)
qry_poll_timer <= 10'd0;
ddram_rd_addr <= QUERY_CTRL_ADDR;
ddram_rd_req  <= ~ddram_rd_req;
return_state  <= S_QRY_PARSE;
state         <= S_DD_RD_WAIT;
end
end

// =============================================================
S_DD_WR_WAIT: begin
ddram_wait_timeout <= ddram_wait_timeout + 20'd1;
if (ddram_wr_req == dwr_ack_s2) begin
ddram_wait_timeout <= 20'd0;
state <= return_state;
end else if (ddram_wait_timeout >= 20'hFFFFF) begin
// Timeout (~32ms at 33MHz) - abort this VBlank cycle to avoid permanent stall
ddram_wait_timeout <= 20'd0;
state <= S_IDLE;
end
end

S_DD_RD_WAIT: begin
ddram_wait_timeout <= ddram_wait_timeout + 20'd1;
if (ddram_rd_req == drd_ack_s2) begin
ddram_wait_timeout <= 20'd0;
rd_data <= ddram_rd_dout;
state   <= return_state;
end else if (ddram_wait_timeout >= 20'hFFFFF) begin
// Timeout - abort this VBlank cycle
ddram_wait_timeout <= 20'd0;
state <= S_IDLE;
end
end

// =============================================================
S_READ_HDR: begin
ddram_rd_addr <= ADDRLIST_BASE;
ddram_rd_req  <= ~ddram_rd_req;
return_state  <= S_PARSE_HDR;
state         <= S_DD_RD_WAIT;
end

S_PARSE_HDR: begin
req_id <= rd_data[63:32];
if (rd_data[31:0] == 32'd0) begin
req_count <= 32'd0;
state     <= S_WRITE_RESP;
end else begin
req_count    <= (rd_data[31:0] > {19'd0, MAX_ADDRS}) ?
                {19'd0, MAX_ADDRS} : rd_data[31:0];
addr_idx     <= 13'd0;
collect_cnt  <= 4'd0;
collect_buf  <= 64'd0;
val_word_idx <= 13'd0;
state        <= S_READ_PAIR;
end
end

// =============================================================
S_READ_PAIR: begin
ddram_rd_addr <= ADDRLIST_BASE + 29'd1 + {16'd0, addr_idx[12:1]};
ddram_rd_req  <= ~ddram_rd_req;
return_state  <= S_PARSE_ADDR;
state         <= S_DD_RD_WAIT;
end

S_PARSE_ADDR: begin
if (!addr_idx[0]) begin
addr_word <= rd_data;
cur_addr  <= rd_data[31:0];
end else begin
cur_addr <= addr_word[63:32];
end
state <= S_DISPATCH;
end

// =============================================================
S_DISPATCH: begin
dbg_dispatch_cnt <= dbg_dispatch_cnt + 8'd1;
if (!dbg_dispatch_cnt)
dbg_first_addr <= cur_addr[15:0];
if (BYPASS_SDRAM) begin
fetch_byte <= cur_addr[7:0] ^ 8'hA5;
state      <= S_STORE_VAL;
end
else begin
state <= S_FETCH_RAM;
end
end

// =============================================================
// SDRAM CH4 read: byte from Main RAM
// =============================================================
S_FETCH_RAM: begin
// Removed vblank guard - CH4 interface handles SDRAM arbitration.
// The previous 'if (vblank)' caused permanent stalls when VBlank
// stopped pulsing (e.g., during PSX video mode changes).
ch4_addr        <= {6'b0, cur_addr[20:0]};
ch4_req         <= 1'b1;
ch4_req_pending <= 1'b1;
ch4_phase       <= 1'b0;
timeout         <= 16'd0;
state           <= S_RAM_WAIT;
end

S_RAM_WAIT: begin
timeout <= timeout + 16'd1;
if (!ch4_phase) begin
ch4_phase <= 1'b1;
end else begin
if (ch4_ready) begin
fetch_byte <= cur_addr[0] ? ch4_dout[15:8] : ch4_dout[7:0];
ch4_req_pending <= 1'b0;
dbg_ok_cnt <= dbg_ok_cnt + 16'd1;
if (!dbg_first_cap) begin
dbg_first_dout <= ch4_dout[15:0];
dbg_first_cap  <= 1'b1;
end
if (timeout > dbg_max_timeout)
dbg_max_timeout <= timeout;
state <= S_STORE_VAL;
end
end
if (timeout >= 16'hFFFF) begin
fetch_byte <= 8'd0;
ch4_req_pending <= 1'b0;
dbg_timeout_cnt <= dbg_timeout_cnt + 16'd1;
state <= S_STORE_VAL;
end
end

// =============================================================
S_STORE_VAL: begin
case (collect_cnt[2:0])
3'd0: collect_buf[ 7: 0] <= fetch_byte;
3'd1: collect_buf[15: 8] <= fetch_byte;
3'd2: collect_buf[23:16] <= fetch_byte;
3'd3: collect_buf[31:24] <= fetch_byte;
3'd4: collect_buf[39:32] <= fetch_byte;
3'd5: collect_buf[47:40] <= fetch_byte;
3'd6: collect_buf[55:48] <= fetch_byte;
3'd7: collect_buf[63:56] <= fetch_byte;
endcase
collect_cnt <= collect_cnt + 4'd1;
addr_idx    <= addr_idx + 13'd1;

if (collect_cnt == 4'd7 || (addr_idx + 13'd1 >= req_count[12:0])) begin
state <= S_FLUSH_BUF;
end
else if (addr_idx[0]) begin
state <= S_READ_PAIR;
end else begin
state <= S_PARSE_ADDR;
end
end

// =============================================================
S_FLUSH_BUF: begin
ddram_wr_addr <= VALCACHE_BASE + 29'd1 + {16'd0, val_word_idx};
ddram_wr_din  <= collect_buf;
ddram_wr_be   <= (collect_cnt == 4'd8) ? 8'hFF
                 : ((8'd1 << collect_cnt[2:0]) - 8'd1);
ddram_wr_req  <= ~ddram_wr_req;
val_word_idx  <= val_word_idx + 13'd1;
collect_cnt   <= 4'd0;
collect_buf   <= 64'd0;

if (addr_idx >= req_count[12:0]) begin
return_state <= S_WRITE_RESP;
end else if (!addr_idx[0]) begin
return_state <= S_READ_PAIR;
end else begin
return_state <= S_PARSE_ADDR;
end
state <= S_DD_WR_WAIT;
end

// =============================================================
S_WRITE_RESP: begin
ddram_wr_addr <= VALCACHE_BASE;
ddram_wr_din  <= {frame_counter + 32'd1, req_id};
ddram_wr_be   <= 8'hFF;
ddram_wr_req  <= ~ddram_wr_req;
return_state  <= S_WR_HDR0;
state         <= S_DD_WR_WAIT;
end

S_WR_HDR0: begin
ddram_wr_addr <= DDRAM_BASE;
ddram_wr_din  <= {16'd0, 8'h00, 8'd0, 32'h52414348};
ddram_wr_be   <= 8'hFF;
ddram_wr_req  <= ~ddram_wr_req;
return_state  <= S_WR_HDR1;
state         <= S_DD_WR_WAIT;
end

S_WR_HDR1: begin
frame_counter <= frame_counter + 32'd1;
ddram_wr_addr <= DDRAM_BASE + 29'd1;
ddram_wr_din  <= {32'd0, frame_counter + 32'd1};
ddram_wr_be   <= 8'hFF;
ddram_wr_req  <= ~ddram_wr_req;
return_state  <= S_WR_DBG;
state         <= S_DD_WR_WAIT;
end

S_WR_DBG: begin
ddram_wr_addr <= DDRAM_BASE + 29'd2;
ddram_wr_din  <= {FPGA_VERSION, dbg_dispatch_cnt, dbg_first_dout,
                  dbg_timeout_cnt, dbg_ok_cnt};
ddram_wr_be   <= 8'hFF;
ddram_wr_req  <= ~ddram_wr_req;
return_state  <= S_WR_DBG2;
state         <= S_DD_WR_WAIT;
end

S_WR_DBG2: begin
ddram_wr_addr <= DDRAM_BASE + 29'd3;
ddram_wr_din  <= {dbg_first_addr, 16'd0, 16'd0, dbg_max_timeout};
ddram_wr_be   <= 8'hFF;
ddram_wr_req  <= ~ddram_wr_req;
return_state  <= S_IDLE;
state         <= S_DD_WR_WAIT;
end

// =============================================================
// Realtime Query States (Option C "on steroids")
// =============================================================
S_QRY_PARSE: begin
if (rd_data[7:0] != qry_last_seen_seq && rd_data[15:8] != 8'd0) begin
qry_request_seq <= rd_data[7:0];
qry_num         <= (rd_data[15:8] > {4'd0, MAX_RT_QUERIES}) ?
                   {4'd0, MAX_RT_QUERIES} : rd_data[15:8];
qry_idx         <= 4'd0;
state           <= S_QRY_RD_REQ;
end else begin
state <= S_IDLE;
end
end

S_QRY_RD_REQ: begin
ddram_rd_addr <= QUERY_REQ_BASE + {25'd0, qry_idx};
ddram_rd_req  <= ~ddram_rd_req;
return_state  <= S_QRY_FETCH;
state         <= S_DD_RD_WAIT;
end

S_QRY_FETCH: begin
qry_addr      <= rd_data[31:0];
qry_num_bytes <= (rd_data[39:32] == 8'd0) ? 8'd1 : rd_data[39:32];
qry_value     <= 32'd0;
qry_byte_idx  <= 3'd0;
ch4_addr        <= {6'b0, rd_data[20:0]};
ch4_req         <= 1'b1;
ch4_req_pending <= 1'b1;
qry_ch4_phase   <= 1'b0;
timeout         <= 16'd0;
state           <= S_QRY_WAIT;
end

S_QRY_WAIT: begin
timeout <= timeout + 16'd1;
if (!qry_ch4_phase) begin
qry_ch4_phase <= 1'b1;
end else begin
if (ch4_ready) begin
ch4_req_pending <= 1'b0;
case (qry_addr[0])
1'b0: qry_value <= qry_value | ({24'd0, ch4_dout[7:0]}  << (qry_byte_idx * 8));
1'b1: qry_value <= qry_value | ({24'd0, ch4_dout[15:8]} << (qry_byte_idx * 8));
endcase
qry_byte_idx <= qry_byte_idx + 3'd1;
if (qry_byte_idx + 3'd1 >= qry_num_bytes[2:0]) begin
state <= S_QRY_WR_RESP;
end else begin
qry_addr    <= qry_addr + 32'd1;
ch4_addr    <= {6'b0, qry_addr[20:0] + 21'd1};
ch4_req     <= 1'b1;
ch4_req_pending <= 1'b1;
qry_ch4_phase <= 1'b0;
timeout     <= 16'd0;
end
end
end
if (timeout >= 16'hFFFF) begin
ch4_req_pending <= 1'b0;
qry_byte_idx <= qry_byte_idx + 3'd1;
if (qry_byte_idx + 3'd1 >= qry_num_bytes[2:0]) begin
state <= S_QRY_WR_RESP;
end else begin
qry_addr    <= qry_addr + 32'd1;
ch4_addr    <= {6'b0, qry_addr[20:0] + 21'd1};
ch4_req     <= 1'b1;
ch4_req_pending <= 1'b1;
qry_ch4_phase <= 1'b0;
timeout     <= 16'd0;
end
end
end

S_QRY_WR_RESP: begin
ddram_wr_addr <= QUERY_RESP_BASE + {25'd0, qry_idx};
ddram_wr_din  <= {32'd0, qry_value};
ddram_wr_be   <= 8'hFF;
ddram_wr_req  <= ~ddram_wr_req;
qry_idx       <= qry_idx + 4'd1;
if (qry_idx + 4'd1 >= qry_num[3:0]) begin
return_state <= S_QRY_WR_CTRL;
end else begin
return_state <= S_QRY_RD_REQ;
end
state <= S_DD_WR_WAIT;
end

S_QRY_WR_CTRL: begin
qry_last_seen_seq <= qry_request_seq;
ddram_wr_addr     <= QUERY_CTRL_ADDR;
ddram_wr_din      <= {24'd0, qry_request_seq, 16'd0, qry_num[7:0], qry_request_seq};
ddram_wr_be       <= 8'hFF;
ddram_wr_req      <= ~ddram_wr_req;
return_state      <= S_IDLE;
state             <= S_DD_WR_WAIT;
end

endcase
end
end

endmodule
