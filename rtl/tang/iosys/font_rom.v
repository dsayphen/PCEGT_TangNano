//
// 8x8 OSD font ROM - GENERATED FILE, DO NOT EDIT.
// Regenerate with:  python tools/gen_font_rom.py
//
// Glyphs: font8x8_basic by Daniel Hepper <daniel@hepper.net>,
// https://github.com/dhepper/font8x8, released into the public domain.
//
// ASCII 0x20..0x7F, 8 rows per glyph, row 0 on top.
// Bit 0 of a row byte is the leftmost pixel.
//
// The address is {char - 0x20, row}, i.e. char_index * 8 + row.
// Mapped to LUT based ROM16 cells - the design has no spare BSRAM.
//

module font_rom (
    input  wire       clk,
    input  wire [9:0] addr,     // 0 .. 767
    output reg  [7:0] data
);

always @(posedge clk) begin
    case (addr)
        // 0x20 ' '
        10'd0  : data <= 8'h00;
        10'd1  : data <= 8'h00;
        10'd2  : data <= 8'h00;
        10'd3  : data <= 8'h00;
        10'd4  : data <= 8'h00;
        10'd5  : data <= 8'h00;
        10'd6  : data <= 8'h00;
        10'd7  : data <= 8'h00;
        // 0x21 '!'
        10'd8  : data <= 8'h18;
        10'd9  : data <= 8'h3C;
        10'd10 : data <= 8'h3C;
        10'd11 : data <= 8'h18;
        10'd12 : data <= 8'h18;
        10'd13 : data <= 8'h00;
        10'd14 : data <= 8'h18;
        10'd15 : data <= 8'h00;
        // 0x22 '"'
        10'd16 : data <= 8'h36;
        10'd17 : data <= 8'h36;
        10'd18 : data <= 8'h00;
        10'd19 : data <= 8'h00;
        10'd20 : data <= 8'h00;
        10'd21 : data <= 8'h00;
        10'd22 : data <= 8'h00;
        10'd23 : data <= 8'h00;
        // 0x23 '#'
        10'd24 : data <= 8'h36;
        10'd25 : data <= 8'h36;
        10'd26 : data <= 8'h7F;
        10'd27 : data <= 8'h36;
        10'd28 : data <= 8'h7F;
        10'd29 : data <= 8'h36;
        10'd30 : data <= 8'h36;
        10'd31 : data <= 8'h00;
        // 0x24 '$'
        10'd32 : data <= 8'h0C;
        10'd33 : data <= 8'h3E;
        10'd34 : data <= 8'h03;
        10'd35 : data <= 8'h1E;
        10'd36 : data <= 8'h30;
        10'd37 : data <= 8'h1F;
        10'd38 : data <= 8'h0C;
        10'd39 : data <= 8'h00;
        // 0x25 '%'
        10'd40 : data <= 8'h00;
        10'd41 : data <= 8'h63;
        10'd42 : data <= 8'h33;
        10'd43 : data <= 8'h18;
        10'd44 : data <= 8'h0C;
        10'd45 : data <= 8'h66;
        10'd46 : data <= 8'h63;
        10'd47 : data <= 8'h00;
        // 0x26 '&'
        10'd48 : data <= 8'h1C;
        10'd49 : data <= 8'h36;
        10'd50 : data <= 8'h1C;
        10'd51 : data <= 8'h6E;
        10'd52 : data <= 8'h3B;
        10'd53 : data <= 8'h33;
        10'd54 : data <= 8'h6E;
        10'd55 : data <= 8'h00;
        // 0x27 '''
        10'd56 : data <= 8'h06;
        10'd57 : data <= 8'h06;
        10'd58 : data <= 8'h03;
        10'd59 : data <= 8'h00;
        10'd60 : data <= 8'h00;
        10'd61 : data <= 8'h00;
        10'd62 : data <= 8'h00;
        10'd63 : data <= 8'h00;
        // 0x28 '('
        10'd64 : data <= 8'h18;
        10'd65 : data <= 8'h0C;
        10'd66 : data <= 8'h06;
        10'd67 : data <= 8'h06;
        10'd68 : data <= 8'h06;
        10'd69 : data <= 8'h0C;
        10'd70 : data <= 8'h18;
        10'd71 : data <= 8'h00;
        // 0x29 ')'
        10'd72 : data <= 8'h06;
        10'd73 : data <= 8'h0C;
        10'd74 : data <= 8'h18;
        10'd75 : data <= 8'h18;
        10'd76 : data <= 8'h18;
        10'd77 : data <= 8'h0C;
        10'd78 : data <= 8'h06;
        10'd79 : data <= 8'h00;
        // 0x2A '*'
        10'd80 : data <= 8'h00;
        10'd81 : data <= 8'h66;
        10'd82 : data <= 8'h3C;
        10'd83 : data <= 8'hFF;
        10'd84 : data <= 8'h3C;
        10'd85 : data <= 8'h66;
        10'd86 : data <= 8'h00;
        10'd87 : data <= 8'h00;
        // 0x2B '+'
        10'd88 : data <= 8'h00;
        10'd89 : data <= 8'h0C;
        10'd90 : data <= 8'h0C;
        10'd91 : data <= 8'h3F;
        10'd92 : data <= 8'h0C;
        10'd93 : data <= 8'h0C;
        10'd94 : data <= 8'h00;
        10'd95 : data <= 8'h00;
        // 0x2C ','
        10'd96 : data <= 8'h00;
        10'd97 : data <= 8'h00;
        10'd98 : data <= 8'h00;
        10'd99 : data <= 8'h00;
        10'd100: data <= 8'h00;
        10'd101: data <= 8'h0C;
        10'd102: data <= 8'h0C;
        10'd103: data <= 8'h06;
        // 0x2D '-'
        10'd104: data <= 8'h00;
        10'd105: data <= 8'h00;
        10'd106: data <= 8'h00;
        10'd107: data <= 8'h3F;
        10'd108: data <= 8'h00;
        10'd109: data <= 8'h00;
        10'd110: data <= 8'h00;
        10'd111: data <= 8'h00;
        // 0x2E '.'
        10'd112: data <= 8'h00;
        10'd113: data <= 8'h00;
        10'd114: data <= 8'h00;
        10'd115: data <= 8'h00;
        10'd116: data <= 8'h00;
        10'd117: data <= 8'h0C;
        10'd118: data <= 8'h0C;
        10'd119: data <= 8'h00;
        // 0x2F '/'
        10'd120: data <= 8'h60;
        10'd121: data <= 8'h30;
        10'd122: data <= 8'h18;
        10'd123: data <= 8'h0C;
        10'd124: data <= 8'h06;
        10'd125: data <= 8'h03;
        10'd126: data <= 8'h01;
        10'd127: data <= 8'h00;
        // 0x30 '0'
        10'd128: data <= 8'h3E;
        10'd129: data <= 8'h63;
        10'd130: data <= 8'h73;
        10'd131: data <= 8'h7B;
        10'd132: data <= 8'h6F;
        10'd133: data <= 8'h67;
        10'd134: data <= 8'h3E;
        10'd135: data <= 8'h00;
        // 0x31 '1'
        10'd136: data <= 8'h0C;
        10'd137: data <= 8'h0E;
        10'd138: data <= 8'h0C;
        10'd139: data <= 8'h0C;
        10'd140: data <= 8'h0C;
        10'd141: data <= 8'h0C;
        10'd142: data <= 8'h3F;
        10'd143: data <= 8'h00;
        // 0x32 '2'
        10'd144: data <= 8'h1E;
        10'd145: data <= 8'h33;
        10'd146: data <= 8'h30;
        10'd147: data <= 8'h1C;
        10'd148: data <= 8'h06;
        10'd149: data <= 8'h33;
        10'd150: data <= 8'h3F;
        10'd151: data <= 8'h00;
        // 0x33 '3'
        10'd152: data <= 8'h1E;
        10'd153: data <= 8'h33;
        10'd154: data <= 8'h30;
        10'd155: data <= 8'h1C;
        10'd156: data <= 8'h30;
        10'd157: data <= 8'h33;
        10'd158: data <= 8'h1E;
        10'd159: data <= 8'h00;
        // 0x34 '4'
        10'd160: data <= 8'h38;
        10'd161: data <= 8'h3C;
        10'd162: data <= 8'h36;
        10'd163: data <= 8'h33;
        10'd164: data <= 8'h7F;
        10'd165: data <= 8'h30;
        10'd166: data <= 8'h78;
        10'd167: data <= 8'h00;
        // 0x35 '5'
        10'd168: data <= 8'h3F;
        10'd169: data <= 8'h03;
        10'd170: data <= 8'h1F;
        10'd171: data <= 8'h30;
        10'd172: data <= 8'h30;
        10'd173: data <= 8'h33;
        10'd174: data <= 8'h1E;
        10'd175: data <= 8'h00;
        // 0x36 '6'
        10'd176: data <= 8'h1C;
        10'd177: data <= 8'h06;
        10'd178: data <= 8'h03;
        10'd179: data <= 8'h1F;
        10'd180: data <= 8'h33;
        10'd181: data <= 8'h33;
        10'd182: data <= 8'h1E;
        10'd183: data <= 8'h00;
        // 0x37 '7'
        10'd184: data <= 8'h3F;
        10'd185: data <= 8'h33;
        10'd186: data <= 8'h30;
        10'd187: data <= 8'h18;
        10'd188: data <= 8'h0C;
        10'd189: data <= 8'h0C;
        10'd190: data <= 8'h0C;
        10'd191: data <= 8'h00;
        // 0x38 '8'
        10'd192: data <= 8'h1E;
        10'd193: data <= 8'h33;
        10'd194: data <= 8'h33;
        10'd195: data <= 8'h1E;
        10'd196: data <= 8'h33;
        10'd197: data <= 8'h33;
        10'd198: data <= 8'h1E;
        10'd199: data <= 8'h00;
        // 0x39 '9'
        10'd200: data <= 8'h1E;
        10'd201: data <= 8'h33;
        10'd202: data <= 8'h33;
        10'd203: data <= 8'h3E;
        10'd204: data <= 8'h30;
        10'd205: data <= 8'h18;
        10'd206: data <= 8'h0E;
        10'd207: data <= 8'h00;
        // 0x3A ':'
        10'd208: data <= 8'h00;
        10'd209: data <= 8'h0C;
        10'd210: data <= 8'h0C;
        10'd211: data <= 8'h00;
        10'd212: data <= 8'h00;
        10'd213: data <= 8'h0C;
        10'd214: data <= 8'h0C;
        10'd215: data <= 8'h00;
        // 0x3B ';'
        10'd216: data <= 8'h00;
        10'd217: data <= 8'h0C;
        10'd218: data <= 8'h0C;
        10'd219: data <= 8'h00;
        10'd220: data <= 8'h00;
        10'd221: data <= 8'h0C;
        10'd222: data <= 8'h0C;
        10'd223: data <= 8'h06;
        // 0x3C '<'
        10'd224: data <= 8'h18;
        10'd225: data <= 8'h0C;
        10'd226: data <= 8'h06;
        10'd227: data <= 8'h03;
        10'd228: data <= 8'h06;
        10'd229: data <= 8'h0C;
        10'd230: data <= 8'h18;
        10'd231: data <= 8'h00;
        // 0x3D '='
        10'd232: data <= 8'h00;
        10'd233: data <= 8'h00;
        10'd234: data <= 8'h3F;
        10'd235: data <= 8'h00;
        10'd236: data <= 8'h00;
        10'd237: data <= 8'h3F;
        10'd238: data <= 8'h00;
        10'd239: data <= 8'h00;
        // 0x3E '>'
        10'd240: data <= 8'h06;
        10'd241: data <= 8'h0C;
        10'd242: data <= 8'h18;
        10'd243: data <= 8'h30;
        10'd244: data <= 8'h18;
        10'd245: data <= 8'h0C;
        10'd246: data <= 8'h06;
        10'd247: data <= 8'h00;
        // 0x3F '?'
        10'd248: data <= 8'h1E;
        10'd249: data <= 8'h33;
        10'd250: data <= 8'h30;
        10'd251: data <= 8'h18;
        10'd252: data <= 8'h0C;
        10'd253: data <= 8'h00;
        10'd254: data <= 8'h0C;
        10'd255: data <= 8'h00;
        // 0x40 '@'
        10'd256: data <= 8'h3E;
        10'd257: data <= 8'h63;
        10'd258: data <= 8'h7B;
        10'd259: data <= 8'h7B;
        10'd260: data <= 8'h7B;
        10'd261: data <= 8'h03;
        10'd262: data <= 8'h1E;
        10'd263: data <= 8'h00;
        // 0x41 'A'
        10'd264: data <= 8'h0C;
        10'd265: data <= 8'h1E;
        10'd266: data <= 8'h33;
        10'd267: data <= 8'h33;
        10'd268: data <= 8'h3F;
        10'd269: data <= 8'h33;
        10'd270: data <= 8'h33;
        10'd271: data <= 8'h00;
        // 0x42 'B'
        10'd272: data <= 8'h3F;
        10'd273: data <= 8'h66;
        10'd274: data <= 8'h66;
        10'd275: data <= 8'h3E;
        10'd276: data <= 8'h66;
        10'd277: data <= 8'h66;
        10'd278: data <= 8'h3F;
        10'd279: data <= 8'h00;
        // 0x43 'C'
        10'd280: data <= 8'h3C;
        10'd281: data <= 8'h66;
        10'd282: data <= 8'h03;
        10'd283: data <= 8'h03;
        10'd284: data <= 8'h03;
        10'd285: data <= 8'h66;
        10'd286: data <= 8'h3C;
        10'd287: data <= 8'h00;
        // 0x44 'D'
        10'd288: data <= 8'h1F;
        10'd289: data <= 8'h36;
        10'd290: data <= 8'h66;
        10'd291: data <= 8'h66;
        10'd292: data <= 8'h66;
        10'd293: data <= 8'h36;
        10'd294: data <= 8'h1F;
        10'd295: data <= 8'h00;
        // 0x45 'E'
        10'd296: data <= 8'h7F;
        10'd297: data <= 8'h46;
        10'd298: data <= 8'h16;
        10'd299: data <= 8'h1E;
        10'd300: data <= 8'h16;
        10'd301: data <= 8'h46;
        10'd302: data <= 8'h7F;
        10'd303: data <= 8'h00;
        // 0x46 'F'
        10'd304: data <= 8'h7F;
        10'd305: data <= 8'h46;
        10'd306: data <= 8'h16;
        10'd307: data <= 8'h1E;
        10'd308: data <= 8'h16;
        10'd309: data <= 8'h06;
        10'd310: data <= 8'h0F;
        10'd311: data <= 8'h00;
        // 0x47 'G'
        10'd312: data <= 8'h3C;
        10'd313: data <= 8'h66;
        10'd314: data <= 8'h03;
        10'd315: data <= 8'h03;
        10'd316: data <= 8'h73;
        10'd317: data <= 8'h66;
        10'd318: data <= 8'h7C;
        10'd319: data <= 8'h00;
        // 0x48 'H'
        10'd320: data <= 8'h33;
        10'd321: data <= 8'h33;
        10'd322: data <= 8'h33;
        10'd323: data <= 8'h3F;
        10'd324: data <= 8'h33;
        10'd325: data <= 8'h33;
        10'd326: data <= 8'h33;
        10'd327: data <= 8'h00;
        // 0x49 'I'
        10'd328: data <= 8'h1E;
        10'd329: data <= 8'h0C;
        10'd330: data <= 8'h0C;
        10'd331: data <= 8'h0C;
        10'd332: data <= 8'h0C;
        10'd333: data <= 8'h0C;
        10'd334: data <= 8'h1E;
        10'd335: data <= 8'h00;
        // 0x4A 'J'
        10'd336: data <= 8'h78;
        10'd337: data <= 8'h30;
        10'd338: data <= 8'h30;
        10'd339: data <= 8'h30;
        10'd340: data <= 8'h33;
        10'd341: data <= 8'h33;
        10'd342: data <= 8'h1E;
        10'd343: data <= 8'h00;
        // 0x4B 'K'
        10'd344: data <= 8'h67;
        10'd345: data <= 8'h66;
        10'd346: data <= 8'h36;
        10'd347: data <= 8'h1E;
        10'd348: data <= 8'h36;
        10'd349: data <= 8'h66;
        10'd350: data <= 8'h67;
        10'd351: data <= 8'h00;
        // 0x4C 'L'
        10'd352: data <= 8'h0F;
        10'd353: data <= 8'h06;
        10'd354: data <= 8'h06;
        10'd355: data <= 8'h06;
        10'd356: data <= 8'h46;
        10'd357: data <= 8'h66;
        10'd358: data <= 8'h7F;
        10'd359: data <= 8'h00;
        // 0x4D 'M'
        10'd360: data <= 8'h63;
        10'd361: data <= 8'h77;
        10'd362: data <= 8'h7F;
        10'd363: data <= 8'h7F;
        10'd364: data <= 8'h6B;
        10'd365: data <= 8'h63;
        10'd366: data <= 8'h63;
        10'd367: data <= 8'h00;
        // 0x4E 'N'
        10'd368: data <= 8'h63;
        10'd369: data <= 8'h67;
        10'd370: data <= 8'h6F;
        10'd371: data <= 8'h7B;
        10'd372: data <= 8'h73;
        10'd373: data <= 8'h63;
        10'd374: data <= 8'h63;
        10'd375: data <= 8'h00;
        // 0x4F 'O'
        10'd376: data <= 8'h1C;
        10'd377: data <= 8'h36;
        10'd378: data <= 8'h63;
        10'd379: data <= 8'h63;
        10'd380: data <= 8'h63;
        10'd381: data <= 8'h36;
        10'd382: data <= 8'h1C;
        10'd383: data <= 8'h00;
        // 0x50 'P'
        10'd384: data <= 8'h3F;
        10'd385: data <= 8'h66;
        10'd386: data <= 8'h66;
        10'd387: data <= 8'h3E;
        10'd388: data <= 8'h06;
        10'd389: data <= 8'h06;
        10'd390: data <= 8'h0F;
        10'd391: data <= 8'h00;
        // 0x51 'Q'
        10'd392: data <= 8'h1E;
        10'd393: data <= 8'h33;
        10'd394: data <= 8'h33;
        10'd395: data <= 8'h33;
        10'd396: data <= 8'h3B;
        10'd397: data <= 8'h1E;
        10'd398: data <= 8'h38;
        10'd399: data <= 8'h00;
        // 0x52 'R'
        10'd400: data <= 8'h3F;
        10'd401: data <= 8'h66;
        10'd402: data <= 8'h66;
        10'd403: data <= 8'h3E;
        10'd404: data <= 8'h36;
        10'd405: data <= 8'h66;
        10'd406: data <= 8'h67;
        10'd407: data <= 8'h00;
        // 0x53 'S'
        10'd408: data <= 8'h1E;
        10'd409: data <= 8'h33;
        10'd410: data <= 8'h07;
        10'd411: data <= 8'h0E;
        10'd412: data <= 8'h38;
        10'd413: data <= 8'h33;
        10'd414: data <= 8'h1E;
        10'd415: data <= 8'h00;
        // 0x54 'T'
        10'd416: data <= 8'h3F;
        10'd417: data <= 8'h2D;
        10'd418: data <= 8'h0C;
        10'd419: data <= 8'h0C;
        10'd420: data <= 8'h0C;
        10'd421: data <= 8'h0C;
        10'd422: data <= 8'h1E;
        10'd423: data <= 8'h00;
        // 0x55 'U'
        10'd424: data <= 8'h33;
        10'd425: data <= 8'h33;
        10'd426: data <= 8'h33;
        10'd427: data <= 8'h33;
        10'd428: data <= 8'h33;
        10'd429: data <= 8'h33;
        10'd430: data <= 8'h3F;
        10'd431: data <= 8'h00;
        // 0x56 'V'
        10'd432: data <= 8'h33;
        10'd433: data <= 8'h33;
        10'd434: data <= 8'h33;
        10'd435: data <= 8'h33;
        10'd436: data <= 8'h33;
        10'd437: data <= 8'h1E;
        10'd438: data <= 8'h0C;
        10'd439: data <= 8'h00;
        // 0x57 'W'
        10'd440: data <= 8'h63;
        10'd441: data <= 8'h63;
        10'd442: data <= 8'h63;
        10'd443: data <= 8'h6B;
        10'd444: data <= 8'h7F;
        10'd445: data <= 8'h77;
        10'd446: data <= 8'h63;
        10'd447: data <= 8'h00;
        // 0x58 'X'
        10'd448: data <= 8'h63;
        10'd449: data <= 8'h63;
        10'd450: data <= 8'h36;
        10'd451: data <= 8'h1C;
        10'd452: data <= 8'h1C;
        10'd453: data <= 8'h36;
        10'd454: data <= 8'h63;
        10'd455: data <= 8'h00;
        // 0x59 'Y'
        10'd456: data <= 8'h33;
        10'd457: data <= 8'h33;
        10'd458: data <= 8'h33;
        10'd459: data <= 8'h1E;
        10'd460: data <= 8'h0C;
        10'd461: data <= 8'h0C;
        10'd462: data <= 8'h1E;
        10'd463: data <= 8'h00;
        // 0x5A 'Z'
        10'd464: data <= 8'h7F;
        10'd465: data <= 8'h63;
        10'd466: data <= 8'h31;
        10'd467: data <= 8'h18;
        10'd468: data <= 8'h4C;
        10'd469: data <= 8'h66;
        10'd470: data <= 8'h7F;
        10'd471: data <= 8'h00;
        // 0x5B '['
        10'd472: data <= 8'h1E;
        10'd473: data <= 8'h06;
        10'd474: data <= 8'h06;
        10'd475: data <= 8'h06;
        10'd476: data <= 8'h06;
        10'd477: data <= 8'h06;
        10'd478: data <= 8'h1E;
        10'd479: data <= 8'h00;
        // 0x5C '\'
        10'd480: data <= 8'h03;
        10'd481: data <= 8'h06;
        10'd482: data <= 8'h0C;
        10'd483: data <= 8'h18;
        10'd484: data <= 8'h30;
        10'd485: data <= 8'h60;
        10'd486: data <= 8'h40;
        10'd487: data <= 8'h00;
        // 0x5D ']'
        10'd488: data <= 8'h1E;
        10'd489: data <= 8'h18;
        10'd490: data <= 8'h18;
        10'd491: data <= 8'h18;
        10'd492: data <= 8'h18;
        10'd493: data <= 8'h18;
        10'd494: data <= 8'h1E;
        10'd495: data <= 8'h00;
        // 0x5E '^'
        10'd496: data <= 8'h08;
        10'd497: data <= 8'h1C;
        10'd498: data <= 8'h36;
        10'd499: data <= 8'h63;
        10'd500: data <= 8'h00;
        10'd501: data <= 8'h00;
        10'd502: data <= 8'h00;
        10'd503: data <= 8'h00;
        // 0x5F '_'
        10'd504: data <= 8'h00;
        10'd505: data <= 8'h00;
        10'd506: data <= 8'h00;
        10'd507: data <= 8'h00;
        10'd508: data <= 8'h00;
        10'd509: data <= 8'h00;
        10'd510: data <= 8'h00;
        10'd511: data <= 8'hFF;
        // 0x60 '`'
        10'd512: data <= 8'h0C;
        10'd513: data <= 8'h0C;
        10'd514: data <= 8'h18;
        10'd515: data <= 8'h00;
        10'd516: data <= 8'h00;
        10'd517: data <= 8'h00;
        10'd518: data <= 8'h00;
        10'd519: data <= 8'h00;
        // 0x61 'a'
        10'd520: data <= 8'h00;
        10'd521: data <= 8'h00;
        10'd522: data <= 8'h1E;
        10'd523: data <= 8'h30;
        10'd524: data <= 8'h3E;
        10'd525: data <= 8'h33;
        10'd526: data <= 8'h6E;
        10'd527: data <= 8'h00;
        // 0x62 'b'
        10'd528: data <= 8'h07;
        10'd529: data <= 8'h06;
        10'd530: data <= 8'h06;
        10'd531: data <= 8'h3E;
        10'd532: data <= 8'h66;
        10'd533: data <= 8'h66;
        10'd534: data <= 8'h3B;
        10'd535: data <= 8'h00;
        // 0x63 'c'
        10'd536: data <= 8'h00;
        10'd537: data <= 8'h00;
        10'd538: data <= 8'h1E;
        10'd539: data <= 8'h33;
        10'd540: data <= 8'h03;
        10'd541: data <= 8'h33;
        10'd542: data <= 8'h1E;
        10'd543: data <= 8'h00;
        // 0x64 'd'
        10'd544: data <= 8'h38;
        10'd545: data <= 8'h30;
        10'd546: data <= 8'h30;
        10'd547: data <= 8'h3E;
        10'd548: data <= 8'h33;
        10'd549: data <= 8'h33;
        10'd550: data <= 8'h6E;
        10'd551: data <= 8'h00;
        // 0x65 'e'
        10'd552: data <= 8'h00;
        10'd553: data <= 8'h00;
        10'd554: data <= 8'h1E;
        10'd555: data <= 8'h33;
        10'd556: data <= 8'h3F;
        10'd557: data <= 8'h03;
        10'd558: data <= 8'h1E;
        10'd559: data <= 8'h00;
        // 0x66 'f'
        10'd560: data <= 8'h1C;
        10'd561: data <= 8'h36;
        10'd562: data <= 8'h06;
        10'd563: data <= 8'h0F;
        10'd564: data <= 8'h06;
        10'd565: data <= 8'h06;
        10'd566: data <= 8'h0F;
        10'd567: data <= 8'h00;
        // 0x67 'g'
        10'd568: data <= 8'h00;
        10'd569: data <= 8'h00;
        10'd570: data <= 8'h6E;
        10'd571: data <= 8'h33;
        10'd572: data <= 8'h33;
        10'd573: data <= 8'h3E;
        10'd574: data <= 8'h30;
        10'd575: data <= 8'h1F;
        // 0x68 'h'
        10'd576: data <= 8'h07;
        10'd577: data <= 8'h06;
        10'd578: data <= 8'h36;
        10'd579: data <= 8'h6E;
        10'd580: data <= 8'h66;
        10'd581: data <= 8'h66;
        10'd582: data <= 8'h67;
        10'd583: data <= 8'h00;
        // 0x69 'i'
        10'd584: data <= 8'h0C;
        10'd585: data <= 8'h00;
        10'd586: data <= 8'h0E;
        10'd587: data <= 8'h0C;
        10'd588: data <= 8'h0C;
        10'd589: data <= 8'h0C;
        10'd590: data <= 8'h1E;
        10'd591: data <= 8'h00;
        // 0x6A 'j'
        10'd592: data <= 8'h30;
        10'd593: data <= 8'h00;
        10'd594: data <= 8'h30;
        10'd595: data <= 8'h30;
        10'd596: data <= 8'h30;
        10'd597: data <= 8'h33;
        10'd598: data <= 8'h33;
        10'd599: data <= 8'h1E;
        // 0x6B 'k'
        10'd600: data <= 8'h07;
        10'd601: data <= 8'h06;
        10'd602: data <= 8'h66;
        10'd603: data <= 8'h36;
        10'd604: data <= 8'h1E;
        10'd605: data <= 8'h36;
        10'd606: data <= 8'h67;
        10'd607: data <= 8'h00;
        // 0x6C 'l'
        10'd608: data <= 8'h0E;
        10'd609: data <= 8'h0C;
        10'd610: data <= 8'h0C;
        10'd611: data <= 8'h0C;
        10'd612: data <= 8'h0C;
        10'd613: data <= 8'h0C;
        10'd614: data <= 8'h1E;
        10'd615: data <= 8'h00;
        // 0x6D 'm'
        10'd616: data <= 8'h00;
        10'd617: data <= 8'h00;
        10'd618: data <= 8'h33;
        10'd619: data <= 8'h7F;
        10'd620: data <= 8'h7F;
        10'd621: data <= 8'h6B;
        10'd622: data <= 8'h63;
        10'd623: data <= 8'h00;
        // 0x6E 'n'
        10'd624: data <= 8'h00;
        10'd625: data <= 8'h00;
        10'd626: data <= 8'h1F;
        10'd627: data <= 8'h33;
        10'd628: data <= 8'h33;
        10'd629: data <= 8'h33;
        10'd630: data <= 8'h33;
        10'd631: data <= 8'h00;
        // 0x6F 'o'
        10'd632: data <= 8'h00;
        10'd633: data <= 8'h00;
        10'd634: data <= 8'h1E;
        10'd635: data <= 8'h33;
        10'd636: data <= 8'h33;
        10'd637: data <= 8'h33;
        10'd638: data <= 8'h1E;
        10'd639: data <= 8'h00;
        // 0x70 'p'
        10'd640: data <= 8'h00;
        10'd641: data <= 8'h00;
        10'd642: data <= 8'h3B;
        10'd643: data <= 8'h66;
        10'd644: data <= 8'h66;
        10'd645: data <= 8'h3E;
        10'd646: data <= 8'h06;
        10'd647: data <= 8'h0F;
        // 0x71 'q'
        10'd648: data <= 8'h00;
        10'd649: data <= 8'h00;
        10'd650: data <= 8'h6E;
        10'd651: data <= 8'h33;
        10'd652: data <= 8'h33;
        10'd653: data <= 8'h3E;
        10'd654: data <= 8'h30;
        10'd655: data <= 8'h78;
        // 0x72 'r'
        10'd656: data <= 8'h00;
        10'd657: data <= 8'h00;
        10'd658: data <= 8'h3B;
        10'd659: data <= 8'h6E;
        10'd660: data <= 8'h66;
        10'd661: data <= 8'h06;
        10'd662: data <= 8'h0F;
        10'd663: data <= 8'h00;
        // 0x73 's'
        10'd664: data <= 8'h00;
        10'd665: data <= 8'h00;
        10'd666: data <= 8'h3E;
        10'd667: data <= 8'h03;
        10'd668: data <= 8'h1E;
        10'd669: data <= 8'h30;
        10'd670: data <= 8'h1F;
        10'd671: data <= 8'h00;
        // 0x74 't'
        10'd672: data <= 8'h08;
        10'd673: data <= 8'h0C;
        10'd674: data <= 8'h3E;
        10'd675: data <= 8'h0C;
        10'd676: data <= 8'h0C;
        10'd677: data <= 8'h2C;
        10'd678: data <= 8'h18;
        10'd679: data <= 8'h00;
        // 0x75 'u'
        10'd680: data <= 8'h00;
        10'd681: data <= 8'h00;
        10'd682: data <= 8'h33;
        10'd683: data <= 8'h33;
        10'd684: data <= 8'h33;
        10'd685: data <= 8'h33;
        10'd686: data <= 8'h6E;
        10'd687: data <= 8'h00;
        // 0x76 'v'
        10'd688: data <= 8'h00;
        10'd689: data <= 8'h00;
        10'd690: data <= 8'h33;
        10'd691: data <= 8'h33;
        10'd692: data <= 8'h33;
        10'd693: data <= 8'h1E;
        10'd694: data <= 8'h0C;
        10'd695: data <= 8'h00;
        // 0x77 'w'
        10'd696: data <= 8'h00;
        10'd697: data <= 8'h00;
        10'd698: data <= 8'h63;
        10'd699: data <= 8'h6B;
        10'd700: data <= 8'h7F;
        10'd701: data <= 8'h7F;
        10'd702: data <= 8'h36;
        10'd703: data <= 8'h00;
        // 0x78 'x'
        10'd704: data <= 8'h00;
        10'd705: data <= 8'h00;
        10'd706: data <= 8'h63;
        10'd707: data <= 8'h36;
        10'd708: data <= 8'h1C;
        10'd709: data <= 8'h36;
        10'd710: data <= 8'h63;
        10'd711: data <= 8'h00;
        // 0x79 'y'
        10'd712: data <= 8'h00;
        10'd713: data <= 8'h00;
        10'd714: data <= 8'h33;
        10'd715: data <= 8'h33;
        10'd716: data <= 8'h33;
        10'd717: data <= 8'h3E;
        10'd718: data <= 8'h30;
        10'd719: data <= 8'h1F;
        // 0x7A 'z'
        10'd720: data <= 8'h00;
        10'd721: data <= 8'h00;
        10'd722: data <= 8'h3F;
        10'd723: data <= 8'h19;
        10'd724: data <= 8'h0C;
        10'd725: data <= 8'h26;
        10'd726: data <= 8'h3F;
        10'd727: data <= 8'h00;
        // 0x7B '{'
        10'd728: data <= 8'h38;
        10'd729: data <= 8'h0C;
        10'd730: data <= 8'h0C;
        10'd731: data <= 8'h07;
        10'd732: data <= 8'h0C;
        10'd733: data <= 8'h0C;
        10'd734: data <= 8'h38;
        10'd735: data <= 8'h00;
        // 0x7C '|'
        10'd736: data <= 8'h18;
        10'd737: data <= 8'h18;
        10'd738: data <= 8'h18;
        10'd739: data <= 8'h00;
        10'd740: data <= 8'h18;
        10'd741: data <= 8'h18;
        10'd742: data <= 8'h18;
        10'd743: data <= 8'h00;
        // 0x7D '}'
        10'd744: data <= 8'h07;
        10'd745: data <= 8'h0C;
        10'd746: data <= 8'h0C;
        10'd747: data <= 8'h38;
        10'd748: data <= 8'h0C;
        10'd749: data <= 8'h0C;
        10'd750: data <= 8'h07;
        10'd751: data <= 8'h00;
        // 0x7E '~'
        10'd752: data <= 8'h6E;
        10'd753: data <= 8'h3B;
        10'd754: data <= 8'h00;
        10'd755: data <= 8'h00;
        10'd756: data <= 8'h00;
        10'd757: data <= 8'h00;
        10'd758: data <= 8'h00;
        10'd759: data <= 8'h00;
        // 0x7F ' '
        10'd760: data <= 8'h00;
        10'd761: data <= 8'h00;
        10'd762: data <= 8'h00;
        10'd763: data <= 8'h00;
        10'd764: data <= 8'h00;
        10'd765: data <= 8'h00;
        10'd766: data <= 8'h00;
        10'd767: data <= 8'h00;
        default: data <= 8'h00;
    endcase
end

endmodule
