// Same-clock IOSys level/pulse interfaces to the SDRAM host toggle interface.
module megadrive_host_bridge (
    input wire clk, resetn, loading,
    input wire ld_wr,
    input wire [22:0] ld_addr,
    input wire [7:0] ld_data,
    output wire ld_busy, ld_idle,
    input wire rv_valid,
    input wire [22:0] rv_addr,
    input wire [31:0] rv_wdata,
    input wire [3:0] rv_wstrb,
    output reg rv_ready,
    output reg [31:0] rv_rdata,
    output reg [22:2] host_addr,
    output reg [31:0] host_wdata,
    output reg [3:0] host_be,
    output reg host_we, host_req,
    input wire host_ack,
    input wire [31:0] host_rdata,
    output wire ram_initializing,
    output reg protocol_fault
);
    localparam IDLE = 2'd0, WAIT_ACK = 2'd1;
    localparam RV = 2'd0, LOADER = 2'd1, CLEAR = 2'd2;
    reg [1:0] state, owner;
    reg loading_d, pending, rv_served, prefer_loader, clearing;
    reg [22:0] pending_addr;
    reg [7:0] pending_data;
    reg [15:0] clear_word;
    wire new_load = loading && !loading_d;
    assign ram_initializing = clearing || new_load;
    assign ld_busy = pending || ld_wr || ram_initializing;
    assign ld_idle = !ld_busy && !(state == WAIT_ACK && owner != RV);
    // IOSys's 1664 KiB firmware window occupies 600000-79FFFF.
    wire [22:0] clear_addr = clear_word < 16'h4000 ?
                             23'h7a0000 + {5'b0, clear_word, 2'b00} :
                             23'h7c0000 + {5'b0, clear_word - 16'h4000, 2'b00};

    always @(posedge clk) begin
        rv_ready <= 0;
        if (!resetn) begin
            state <= IDLE;
            owner <= RV;
            loading_d <= 0;
            pending <= 0;
            rv_served <= 0;
            prefer_loader <= 0;
            clearing <= 0;
            clear_word <= 0;
            pending_addr <= 0;
            pending_data <= 0;
            rv_rdata <= 0;
            host_addr <= 0;
            host_wdata <= 0;
            host_be <= 0;
            host_we <= 0;
            host_req <= 0;
            protocol_fault <= 0;
        end else begin
            loading_d <= loading;
            if (!rv_valid) rv_served <= 0;
            if (new_load) begin
                clearing <= 1;
                clear_word <= 0;
                if (clearing || pending || (state != IDLE && owner != RV))
                    protocol_fault <= 1;
            end
            if (ld_wr) begin
                if (pending || ld_addr >= 23'h600000)
                    protocol_fault <= 1;
                else begin
                    pending <= 1;
                    pending_addr <= ld_addr;
                    pending_data <= ld_data;
                end
            end
            case (state)
                IDLE: if (!new_load) begin
                    if (rv_valid && !rv_served &&
                        (!prefer_loader || (!pending && !clearing))) begin
                        host_addr <= rv_addr[22:2];
                        host_wdata <= rv_wdata;
                        host_be <= rv_wstrb;
                        host_we <= |rv_wstrb;
                        host_req <= ~host_req;
                        owner <= RV;
                        rv_served <= 1;
                        prefer_loader <= 1;
                        state <= WAIT_ACK;
                    end else if (clearing) begin
                        host_addr <= clear_addr[22:2];
                        host_wdata <= clear_word < 16'h4000 ? 32'h00000000 : 32'hffffffff;
                        host_be <= 4'b1111;
                        host_we <= 1;
                        host_req <= ~host_req;
                        owner <= CLEAR;
                        prefer_loader <= 0;
                        state <= WAIT_ACK;
                    end else if (pending) begin
                        host_addr <= pending_addr[22:2];
                        host_wdata <= {4{pending_data}};
                        host_be <= 4'b0001 << pending_addr[1:0];
                        host_we <= 1;
                        host_req <= ~host_req;
                        owner <= LOADER;
                        prefer_loader <= 0;
                        state <= WAIT_ACK;
                    end
                end
                WAIT_ACK: if (host_ack == host_req) begin
                    if (owner == RV) begin
                        rv_rdata <= host_rdata;
                        rv_ready <= 1;
                    end else if (owner == LOADER) pending <= 0;
                    else if (clear_word == 16'hbfff) clearing <= 0;
                    else clear_word <= clear_word + 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule
