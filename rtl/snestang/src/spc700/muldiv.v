
import spc700::*;

module MulDiv(
    input CLK,
    input RST_N,
    input EN,
    input SpcALUCtrl_r CTRL,
    input [7:0] A,
    input [7:0] X,
    input [7:0] Y,
    output [15:0] RES,
    output ZO,
    output VO,
    output HO,
    output SO
);

reg [15:0] tResult;
reg tV, tZ, tS;
reg [15:0] mulRes, mulTemp;
reg [15:0] mulA;
reg [7:0] mulY;
reg [16:0] divx;
reg [16:0] yva;
reg [17:0] yvaS;
reg [16:0] yvaN;

always @(posedge CLK) begin
    if(RST_N == 1'b0) begin
      mulA <= {16{1'b0}};
      mulY <= {8{1'b0}};
      mulRes <= {16{1'b0}};
      divx <= {17{1'b0}};
      yva <= {17{1'b0}};
    end else begin
      if(EN == 1'b1) begin
        if(CTRL.secOp == 4'b1110) begin
          mulRes <= mulTemp;
          mulA <= {mulA[14:0],1'b0};
          mulY <= {1'b0,mulY[7:1]};
        end
        else if(CTRL.secOp == 4'b1111) begin
          yva <= yvaN;
        end
        else begin
          mulA <= {8'b00000000,A};
          mulY <= Y;
          mulRes <= {16{1'b0}};
          divx <= {X,9'b000000000};
          yva <= {1'b0,Y,A};
        end
      end
    end
end

// Bit-serial SPC700 DIV (higan), exact for overflow cases (Y >= 2X)
always @* begin
    yvaS = {yva,1'b0};
    yvaN = yvaS[17] ? {yvaS[16:1],1'b1} : yvaS[16:0];
    if (yvaN >= divx) yvaN[0] = ~yvaN[0];
    if (yvaN[0]) yvaN = yvaN - divx;
end

always @* begin
    mulTemp = {16{1'b0}};
    if(CTRL.secOp == 4'b1110) begin
      if(mulY[0] == 1'b1) begin
        mulTemp = mulRes + mulA;
      end
      else begin
        mulTemp = mulRes;
      end
      tResult = mulTemp;
      if(mulTemp[15:8] == 0) begin
        tZ = 1'b1;
      end
      else begin
        tZ = 1'b0;
      end
      tV = 1'b0;
      tS = mulTemp[15];
    end
    else if(CTRL.secOp == 4'b1111) begin
      tResult = {yva[16:9],yva[7:0]};
      if(yva[7:0] == 0) begin
        tZ = 1'b1;
      end
      else begin
        tZ = 1'b0;
      end
      tV = yva[8];
      tS = yva[7];
    end
    else begin
      tResult = {16{1'b0}};
      tZ = 1'b0;
      tV = 1'b0;
      tS = 1'b0;
    end
end

assign RES = tResult;
assign ZO = tZ;
assign VO = tV;
assign SO = tS;
assign HO = Y[3:0] >= X[3:0] ? 1'b1 : 1'b0;

endmodule
