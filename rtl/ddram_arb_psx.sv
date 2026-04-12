// DDRAM Arbiter for PSX RetroAchievements
//
// Sits between PSX core (psx_mister) and the physical DDRAM interface.
// The PSX core is the primary master; the RA module is secondary.
// RA requests are only serviced when PSX is idle on the bus (no WE/RD).
// While servicing RA, PSX sees BUSY=1 to stall its requests.
//
// RA uses toggle req/ack protocol for both write and read channels.

module ddram_arb_psx (
	input         clk,

	// Physical DDRAM interface (directly to top-level DDRAM ports)
	input         PHY_BUSY,
	output  [7:0] PHY_BURSTCNT,
	output [28:0] PHY_ADDR,
	input  [63:0] PHY_DOUT,
	input         PHY_DOUT_READY,
	output        PHY_RD,
	output [63:0] PHY_DIN,
	output  [7:0] PHY_BE,
	output        PHY_WE,

	// PSX core DDRAM interface (from psx_mister)
	output        PSX_BUSY,
	input   [7:0] PSX_BURSTCNT,
	input  [28:0] PSX_ADDR,
	output [63:0] PSX_DOUT,
	output        PSX_DOUT_READY,
	input         PSX_RD,
	input  [63:0] PSX_DIN,
	input   [7:0] PSX_BE,
	input         PSX_WE,

	// RetroAchievements write channel (toggle req/ack)
	input  [28:0] ra_wr_addr,
	input  [63:0] ra_wr_din,
	input   [7:0] ra_wr_be,
	input         ra_wr_req,
	output reg    ra_wr_ack,

	// RetroAchievements read channel (toggle req/ack)
	input  [28:0] ra_rd_addr,
	input         ra_rd_req,
	output reg    ra_rd_ack,
	output reg [63:0] ra_rd_dout
);

// State machine
localparam S_PASSTHRU = 2'd0;
localparam S_RA_WR    = 2'd1;
localparam S_RA_RD    = 2'd2;
localparam S_RA_WAIT  = 2'd3;

reg [1:0] state = S_PASSTHRU;

// Track pending PSX read bursts: after PSX_RD is accepted, we must
// not steal the bus until all DOUT_READY words have been delivered.
reg        psx_rd_active = 0;
reg  [7:0] psx_burst_cnt = 0;

// Combinational mux driven by state
assign PHY_BURSTCNT = (state == S_PASSTHRU) ? PSX_BURSTCNT : 8'd1;
assign PHY_ADDR     = (state == S_PASSTHRU) ? PSX_ADDR     :
                      (state == S_RA_WR)    ? ra_wr_addr   : ra_rd_addr;
assign PHY_DIN      = (state == S_PASSTHRU) ? PSX_DIN      : ra_wr_din;
assign PHY_BE       = (state == S_PASSTHRU) ? PSX_BE       :
                      (state == S_RA_WR)    ? ra_wr_be     : 8'hFF;
assign PHY_WE       = (state == S_RA_WR)    ? 1'b1         :
                      (state == S_PASSTHRU) ? PSX_WE       : 1'b0;
assign PHY_RD       = (state == S_RA_RD)    ? 1'b1         :
                      (state == S_PASSTHRU) ? PSX_RD       : 1'b0;

assign PSX_BUSY       = (state != S_PASSTHRU) ? 1'b1 : PHY_BUSY;
assign PSX_DOUT       = PHY_DOUT;
assign PSX_DOUT_READY = (state == S_PASSTHRU) ? PHY_DOUT_READY : 1'b0;

always @(posedge clk) begin
	// Track pending PSX read bursts
	if (state == S_PASSTHRU) begin
		if (PSX_RD && !PHY_BUSY) begin
			psx_rd_active <= 1'b1;
			psx_burst_cnt <= PSX_BURSTCNT;
		end
		if (psx_rd_active && PHY_DOUT_READY) begin
			if (psx_burst_cnt <= 8'd1)
				psx_rd_active <= 1'b0;
			else
				psx_burst_cnt <= psx_burst_cnt - 8'd1;
		end
	end

	case (state)
	S_PASSTHRU: begin
		// Only steal bus when PSX is idle and no burst data pending
		if (!PSX_WE && !PSX_RD && !PHY_BUSY && !psx_rd_active) begin
			if (ra_wr_req != ra_wr_ack)
				state <= S_RA_WR;
			else if (ra_rd_req != ra_rd_ack)
				state <= S_RA_RD;
		end
	end

	S_RA_WR: begin
		if (!PHY_BUSY) begin
			ra_wr_ack <= ra_wr_req;
			state <= S_PASSTHRU;
		end
	end

	S_RA_RD: begin
		if (!PHY_BUSY) begin
			state <= S_RA_WAIT;
		end
	end

	S_RA_WAIT: begin
		if (PHY_DOUT_READY) begin
			ra_rd_dout <= PHY_DOUT;
			ra_rd_ack <= ra_rd_req;
			state <= S_PASSTHRU;
		end
	end
	endcase
end

endmodule
