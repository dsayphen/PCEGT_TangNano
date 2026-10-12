library IEEE;
use IEEE.std_logic_1164.all;
use ieee.numeric_std.all;
library work;
use work.HUC6280_PKG.all;

entity HUC6280_CPU is
	port( 
		CLK		: in std_logic;
		RST_N		: in std_logic;
		CE			: in std_logic;
		SS_HOLD : in std_logic := '0';
		SS_LOAD : in std_logic := '0';
		SS_DATA : in std_logic_vector(255 downto 0) := (others => '0');
		SS_Q : out std_logic_vector(255 downto 0) := (others => '0');
		  
		A_OUT		: out std_logic_vector(20 downto 0);
		DI			: in std_logic_vector(7 downto 0);
		DO			: out std_logic_vector(7 downto 0);
		WE_N  	: out std_logic;
		RDY		: in std_logic;
		NMI_N		: in std_logic;  
		IRQ1_N	: in std_logic;
		IRQ2_N	: in std_logic;
		IRQT_N	: in std_logic;
		
		VDCNUM	: in std_logic;

		MCYCLE  	: out std_logic;
		CS  		: out std_logic
	);
end HUC6280_CPU;

architecture rtl of HUC6280_CPU is

	signal EN 				: std_logic;
	
	--Registers
	signal A 				: std_logic_vector(7 downto 0);
	signal X 				: std_logic_vector(7 downto 0);
	signal Y 				: std_logic_vector(7 downto 0);
	signal SP 				: std_logic_vector(7 downto 0);
	signal P    			: std_logic_vector(7 downto 0);
	signal PC    			: std_logic_vector(15 downto 0);
	signal AA				: std_logic_vector(15 downto 0);
	signal T 				: std_logic_vector(7 downto 0);
	signal DR 				: std_logic_vector(7 downto 0);
	signal SH 				: std_logic_vector(7 downto 0);
	signal DH 				: std_logic_vector(7 downto 0);
	signal LH 				: std_logic_vector(7 downto 0);
	signal MPR 				: MPR_t;
	
	--Instruction decoder
	signal IR 				: std_logic_vector(7 downto 0);
	signal STATE 			: unsigned(4 downto 0);
	signal MC 				: MCode_r;
	signal NEXT_IR 		: std_logic_vector(7 downto 0);
	signal NEXT_STATE 	: unsigned(4 downto 0);
	signal LAST_CYCLE 	: std_logic;
	signal BRANCH_TAKEN 	: std_logic;
	signal MEM_INST 		: std_logic;
	signal TALT 			: std_logic;
	
	--Buses
	signal ADDR_BUS 		: std_logic_vector(15 downto 0);
	signal MPR_OUT 		: std_logic_vector(7 downto 0);
	signal MPR_LAST 		: std_logic_vector(7 downto 0);

	--ALU
	signal ALU_CTRL 		: ALUCtrl_r;
	signal ALU_L 			: std_logic_vector(7 downto 0);
	signal ALU_OUT 		: std_logic_vector(7 downto 0);
	signal CO 				: std_logic;
	signal VO 				: std_logic;
	signal NO 				: std_logic;
	signal ZO 				: std_logic;
	signal MASK 			: std_logic_vector(7 downto 0);
	
	--Interrupts
	signal GOT_INT 		: std_logic;
	signal RES_INT 		: std_logic;
	signal NMI_INT 		: std_logic;
	signal IRQ1_INT 		: std_logic;
	signal IRQ2_INT 		: std_logic;
	signal IRQT_INT 		: std_logic;
	signal BRK_INT 		: std_logic;
	signal OLD_NMI_N 		: std_logic;
	signal NMI_SYNC 		: std_logic;
	signal NMI_ACTIVE 	: std_logic;
	signal CS_STATE : std_logic;
	signal AG_STATE : std_logic_vector(32 downto 0);
	signal ALU_STATE : std_logic;
	signal MC_STATE : std_logic_vector(41 downto 0);

begin
	
	EN <= RDY and CE and not SS_HOLD;
	CS <= CS_STATE;
	SS_Q <= "0000" & MC_STATE & ALU_STATE & AG_STATE & CS_STATE &
	        NMI_ACTIVE & GOT_INT & IRQT_INT & IRQ2_INT & IRQ1_INT &
	        NMI_INT & RES_INT & NMI_SYNC & OLD_NMI_N & TALT &
	        std_logic_vector(STATE) & IR & MPR_LAST &
	        MPR(7) & MPR(6) & MPR(5) & MPR(4) & MPR(3) & MPR(2) & MPR(1) & MPR(0) &
	        LH & DH & SH & DR & T & P & SP & Y & X & A;

	NEXT_IR <= IR when (STATE /= "00000") else
				 x"00" when GOT_INT = '1' else 
				 DI; 

	
	process(IR, STATE, P, DR)
	begin
		BRANCH_TAKEN <= '0';
		if IR(4 downto 0) = "10000" and STATE = "00001" then
			case IR(7 downto 5) is
				when "000" => BRANCH_TAKEN <= not P(FLAG_N); -- BPL
				when "001" => BRANCH_TAKEN <=     P(FLAG_N); -- BMI
				when "010" => BRANCH_TAKEN <= not P(FLAG_V); -- BVC
				when "011" => BRANCH_TAKEN <=     P(FLAG_V); -- BVS
				when "100" => BRANCH_TAKEN <= not P(FLAG_C); -- BCC
				when "101" => BRANCH_TAKEN <=     P(FLAG_C); -- BCS
				when "110" => BRANCH_TAKEN <= not P(FLAG_Z); -- BNE
				when "111" => BRANCH_TAKEN <=     P(FLAG_Z); -- BEQ
				when others => BRANCH_TAKEN <= '0';
			end case; 
		elsif IR(3 downto 0) = "1111" and STATE = "00101" then
			if DR(to_integer(unsigned(IR(6 downto 4)))) = IR(7) then
				BRANCH_TAKEN <= '1';
			end if; 
		end if; 
	end process;
	
	MEM_INST <= '1' when DI = x"69" or DI = x"65" or DI = x"75" or DI = x"72" or DI = x"61" or DI = x"71" or DI = x"6D" or DI = x"7D" or DI = x"79" or 
								DI = x"29" or DI = x"25" or DI = x"35" or DI = x"32" or DI = x"21" or DI = x"31" or DI = x"2D" or DI = x"3D" or DI = x"39" or
								DI = x"09" or DI = x"05" or DI = x"15" or DI = x"12" or DI = x"01" or DI = x"11" or DI = x"0D" or DI = x"1D" or DI = x"19" or
								DI = x"49" or DI = x"45" or DI = x"55" or DI = x"52" or DI = x"41" or DI = x"51" or DI = x"4D" or DI = x"5D" or DI = x"59"
								else '0';

	
	process(MC, IR, STATE, BRANCH_TAKEN, P, MEM_INST, GOT_INT, A, LH)
	begin
		case MC.STATE_CTRL is
			when "00" => 
				if MEM_INST = '1' and P(FLAG_T) = '1' and STATE = "00000" and GOT_INT = '0' then
					NEXT_STATE <= "01000";
				else
					NEXT_STATE <= STATE + 1; 
				end if;
			when "01" => 
				if P(FLAG_D) = '0' then
					NEXT_STATE <= "00000";
				else
					NEXT_STATE <= STATE + 1;
				end if;
			when "10" => 
				if BRANCH_TAKEN = '1' then
					NEXT_STATE <= STATE + 1;
				else
					NEXT_STATE <= "00000";
				end if; 
			when "11" => 
				if A = x"00" and LH = x"00" then
					NEXT_STATE <= STATE + 1;
				else
					NEXT_STATE <= "01110";
				end if; 
			when others =>
				NEXT_STATE <= STATE;
		end case;
	end process;

	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			IR <= (others=>'0');
			STATE <= (others=>'0');
		elsif rising_edge(CLK) then
			if SS_HOLD = '1' and SS_LOAD = '1' then
				IR <= SS_DATA(159 downto 152);
				STATE <= unsigned(SS_DATA(164 downto 160));
			elsif EN = '1' then
				IR <= NEXT_IR;
				STATE <= NEXT_STATE;
			end if;
		end if;
	end process; 

	LAST_CYCLE <= '1' when NEXT_STATE = "00000" else '0';
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			TALT <= '0';
		elsif rising_edge(CLK) then
			if SS_HOLD = '1' and SS_LOAD = '1' then
				TALT <= SS_DATA(165);
			elsif EN = '1' then
				if STATE = "01101" then
					TALT <= '0';
				elsif STATE = "10011" then
					TALT <= not TALT;
				end if; 
			end if; 
		end if;
	end process;
	
	MCODE: entity work.HUC6280_MC
	port map (
		CLK		=> CLK,
		RST_N		=> RST_N,
		EN			=> EN,
		SS_HOLD => SS_HOLD,
		SS_LOAD => SS_LOAD,
		SS_DATA => SS_DATA(251 downto 210),
		SS_Q => MC_STATE,
		IR			=> NEXT_IR,
		STATE		=> NEXT_STATE,
		M			=> MC
	);
	
	process(MC, IR, STATE, TALT)
	begin
		ALU_CTRL <= MC.ALU_CTRL;
		if IR = x"E3" and (STATE = 16 or STATE = 17) then
			ALU_CTRL.secOp(2) <= TALT;
		elsif IR = x"F3" and (STATE = 14 or STATE = 15) then
			ALU_CTRL.secOp(2) <= TALT;
		end if;
	end process;
		
	process(IR)
	begin
		case IR(6 downto 4) is
			when "000"  => MASK <= x"01";
			when "001"  => MASK <= x"02";
			when "010"  => MASK <= x"04";
			when "011"  => MASK <= x"08";
			when "100"  => MASK <= x"10";
			when "101"  => MASK <= x"20";
			when "110"  => MASK <= x"40";
			when others => MASK <= x"80";
		end case; 
	end process;

	with MC.ALUBUS_CTRL select
		ALU_L <= DI     	when "0000",
					A        when "0001",
					X        when "0010",
					Y        when "0011",
					SP			when "0100",
					T        when "0101",
					SH       when "1000",
					DH       when "1001",
					LH	   	when "1010",
					MPR_OUT	when "1011",
					MASK     when "1100",
					x"00"		when others;
			
	ALU: entity work.ALU
	port map (
		CLK		=> CLK,
		EN			=> EN,
		SS_HOLD => SS_HOLD,
		SS_LOAD => SS_LOAD,
		SS_DATA => SS_DATA(209),
		SS_Q => ALU_STATE,
		L     	=> ALU_L,
		R     	=> DI,
		CTRL   	=> ALU_CTRL,
		BCD     	=> P(FLAG_D),
		CI   	 	=> P(FLAG_C),
		VI  		=> P(FLAG_V),
		NI  		=> P(FLAG_N),
		CO   		=> CO,
		VO    	=> VO,
		NO   		=> NO,
		ZO   		=> ZO,
		RES		=> ALU_OUT
	);

				  
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			A <= (others=>'0');
			X <= (others=>'0');
			Y <= (others=>'0');
		elsif rising_edge(CLK) then
			if SS_HOLD = '1' and SS_LOAD = '1' then
				A <= SS_DATA(7 downto 0);
				X <= SS_DATA(15 downto 8);
				Y <= SS_DATA(23 downto 16);
			elsif EN = '1' then
				if MC.AXY_CTRL(0) = '1' then
					A <= ALU_OUT;
				end if; 
				if MC.AXY_CTRL(1) = '1' then
					X <= ALU_OUT;
				end if; 
				if MC.AXY_CTRL(2) = '1' then
					Y <= ALU_OUT;
				end if; 
			end if; 
		end if;
	end process;
				  
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			T <= (others=>'0');
		elsif rising_edge(CLK) then
			if SS_HOLD = '1' and SS_LOAD = '1' then
				T <= SS_DATA(47 downto 40);
			elsif EN = '1' then
				case MC.LOAD_T is
					when "001" => T <= ALU_OUT;
					when "010" => T <= X;
					when "011" => T <= Y;
					when "100" => T <= DI; 
					when others => null;
				end case;
			end if; 
		end if;
	end process;
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			SP <= (others=>'0');
		elsif rising_edge(CLK) then
			if SS_HOLD = '1' and SS_LOAD = '1' then
				SP <= SS_DATA(31 downto 24);
			elsif EN = '1' then
				case MC.LOAD_SP is
					when "001" => 
						SP <= ALU_OUT;
					when "010"=> 
						SP <= std_logic_vector(unsigned(SP) + 1);
					when "011" => 
						SP <= std_logic_vector(unsigned(SP) - 1);
					when others => null;
				end case;
			end if; 
		end if;
	end process;
	
	--Status register
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			P <= "00000100";
		elsif rising_edge(CLK) then
			if SS_HOLD = '1' and SS_LOAD = '1' then
				P <= SS_DATA(39 downto 32);
			elsif EN = '1' then
				case MC.LOAD_P is
					when "001" =>  -- ALU
						P(FLAG_Z) <= ZO; 
						P(FLAG_N) <= NO;
					when "010" => 	-- BRK/interrupts
						P(FLAG_I) <= '1'; 
						P(FLAG_D) <= '0';	
					when "011" =>  -- RTI/PLP
						P <= DI; 
					when "100" => 
						case IR(7 downto 6) is
							when "00" => P(FLAG_C) <= IR(5); -- CLC/SEC 18/38
							when "01" => P(FLAG_I) <= IR(5); -- CLI/SEI 58/78
							when "10" => P(FLAG_V) <= '0';   -- CLV B8
							when "11" => P(FLAG_D) <= IR(5); -- CLD/SED D8/F8
							when others => null;
						end case;
					when "101" =>  -- ALU
						P(FLAG_C) <= CO; 
						P(FLAG_Z) <= ZO;
						P(FLAG_V) <= VO;
						P(FLAG_N) <= NO;
					when "110" => 	-- SET
						P(FLAG_T) <= '1'; 
					when "111" =>	-- clear T
						P(FLAG_T) <= '0'; 
					when others => null;
				end case;
				
				if NEXT_IR /= x"00" and STATE = "00000" then
					P(FLAG_T) <= '0';  
				end if;
			end if;
		end if;
	end process;
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			SH <= (others=>'0');
			DH <= (others=>'0');
			LH <= (others=>'0');
		elsif rising_edge(CLK) then
			if SS_HOLD = '1' and SS_LOAD = '1' then
				SH <= SS_DATA(63 downto 56);
				DH <= SS_DATA(71 downto 64);
				LH <= SS_DATA(79 downto 72);
			elsif EN = '1' then
				case MC.LOAD_SDLH is
					when "01" => SH <= ALU_OUT;
					when "10" => DH <= ALU_OUT;
					when "11" => LH <= ALU_OUT;
					when others => null;
				end case;
			end if; 
		end if;
	end process;

	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			MPR(0) <= (others=>'0');
			MPR(1) <= (others=>'0');
			MPR(2) <= (others=>'0');
			MPR(3) <= (others=>'0');
			MPR(4) <= (others=>'0');
			MPR(5) <= (others=>'0');
			MPR(6) <= (others=>'0');
			MPR(7) <= (others=>'0');
		elsif rising_edge(CLK) then
			if SS_HOLD = '1' and SS_LOAD = '1' then
				for index in 0 to 7 loop
					MPR(index) <= SS_DATA(87 + index * 8 downto 80 + index * 8);
				end loop;
				MPR_LAST <= SS_DATA(151 downto 144);
			elsif EN = '1' then
				if IR = x"53" and LAST_CYCLE = '1' then	--TAMi
					for i in 0 to 7 loop
						if T(i) = '1' then
							MPR(i) <= A;
						end if;
					end loop;
					MPR_LAST <= A;
				end if;
			end if; 
		end if;
	end process;
	
	MPR_OUT <= MPR(0) when T(0) = '1' else
				  MPR(1) when T(1) = '1' else
				  MPR(2) when T(2) = '1' else
				  MPR(3) when T(3) = '1' else
				  MPR(4) when T(4) = '1' else
				  MPR(5) when T(5) = '1' else
				  MPR(6) when T(6) = '1' else
				  MPR(7) when T(7) = '1' else
				  MPR_LAST;

	--Data bus
	with MC.OUT_BUS select
		DO <= A when "0001",
				X when "0010",
				Y when "0011",
				T when "0100",
				P(7 downto 5) & (not GOT_INT) & P(3 downto 0) when "0101",
				PC(15 downto 8) when "0110",
				PC(7 downto 0) when "0111",
				x"00" when others;
		
	process(MC, RES_INT)
	begin
		WE_N <= '1';
		if MC.OUT_BUS /= "0000" and RES_INT = '0' then
			WE_N <= '0';
		end if;
	end process;
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			DR <= (others=>'0');
		elsif rising_edge(CLK) then
			if SS_HOLD = '1' and SS_LOAD = '1' then
				DR <= SS_DATA(55 downto 48);
			elsif EN = '1' then
				DR <= DI;
			end if; 
		end if;
	end process;
	
	AG: entity work.HUC6280_AG
	port map (
		CLK   		=> CLK,
		RST_N   		=> RST_N,
		CE   			=> EN,
		SS_HOLD => SS_HOLD,
		SS_LOAD => SS_LOAD,
		SS_DATA => SS_DATA(208 downto 176),
		SS_Q => AG_STATE,
		PC_CTRL   	=> MC.LOAD_PC,
		ADDR_CTRL	=> MC.ADDR_CTRL,
		GOT_INT		=> GOT_INT,
		DI 			=> DI,
		X     		=> X, 
		Y     		=> Y, 
		DR    		=> DR,
		PC     		=> PC, 
		AA     		=> AA
	);
	
	--Interrupts
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			OLD_NMI_N <= '1';
			NMI_SYNC <= '0';
		elsif rising_edge(CLK) then
			if SS_HOLD = '1' and SS_LOAD = '1' then
				OLD_NMI_N <= SS_DATA(166);
				NMI_SYNC <= SS_DATA(167);
			elsif CE = '1' and RES_INT = '0' and SS_HOLD = '0' then
				OLD_NMI_N <= NMI_N;
				if NMI_N = '0' and OLD_NMI_N = '1' and NMI_SYNC = '0' then
					NMI_SYNC <= '1';
				elsif NMI_ACTIVE = '1' and LAST_CYCLE = '1' and EN = '1' then
					NMI_SYNC <= '0';
				end if;
			end if;
		end if;
	end process; 
	
	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			RES_INT <= '1';
			NMI_INT <= '0';
			IRQ1_INT <= '0';
			IRQ2_INT <= '0';
			IRQT_INT <= '0';
			GOT_INT <= '1';
			NMI_ACTIVE <= '0';
		elsif rising_edge(CLK) then
			if SS_HOLD = '1' and SS_LOAD = '1' then
				RES_INT <= SS_DATA(168);
				NMI_INT <= SS_DATA(169);
				IRQ1_INT <= SS_DATA(170);
				IRQ2_INT <= SS_DATA(171);
				IRQT_INT <= SS_DATA(172);
				GOT_INT <= SS_DATA(173);
				NMI_ACTIVE <= SS_DATA(174);
			elsif RDY = '1' and CE = '1' and SS_HOLD = '0' then
				NMI_ACTIVE <= NMI_SYNC;
				
				if LAST_CYCLE = '1' and EN = '1' then
					if GOT_INT = '0' then
						GOT_INT <= ((not IRQ1_N or not IRQ2_N or not IRQT_N) and not P(FLAG_I)) or NMI_ACTIVE;
						if NMI_ACTIVE = '1' then
							NMI_ACTIVE <= '0';
						end if;
					else
						GOT_INT <= '0';
					end if;
					
					RES_INT <= '0';
					NMI_INT <= NMI_ACTIVE;
					IRQ1_INT <= not IRQ1_N and not P(FLAG_I);
					IRQ2_INT <= not IRQ2_N and not P(FLAG_I);
					IRQT_INT <= not IRQT_N and not P(FLAG_I);
				end if;
			end if;
		end if;
	end process; 
	
	BRK_INT <= '1' when IR = x"00" and GOT_INT = '0' else '0';

	--Address bus
	process(MC, PC, AA, SP, SH, DH, X, Y, STATE, IR, RES_INT, NMI_INT, BRK_INT, IRQ1_INT, IRQ2_INT, IRQT_INT, VDCNUM)
	begin
		case MC.ADDR_BUS is
			when "000" => 
				ADDR_BUS <= PC; 
			when "001"=> 
				ADDR_BUS <= AA;
			when "010" => 
				ADDR_BUS <= x"21" & SP;
			when "011" => 
				ADDR_BUS <= x"20" & AA(7 downto 0);
			when "100" => 
				ADDR_BUS(15 downto 4) <= x"FFF";
				if RES_INT = '1' then
					ADDR_BUS(3 downto 0) <= "111" & STATE(0);		--FFFE/F
				elsif NMI_INT = '1' then
					ADDR_BUS(3 downto 0) <= "110" & STATE(0);		--FFFC/D
				elsif BRK_INT = '1' then
					ADDR_BUS(3 downto 0) <= "011" & STATE(0);		--FFF6/7
				elsif IRQT_INT = '1' then
					ADDR_BUS(3 downto 0) <= "101" & STATE(0);		--FFFA/B
				elsif IRQ1_INT = '1' then
					ADDR_BUS(3 downto 0) <= "100" & STATE(0);		--FFF8/9
				elsif IRQ2_INT = '1' then
					ADDR_BUS(3 downto 0) <= "011" & STATE(0);		--FFF6/7
				else
					ADDR_BUS(3 downto 0) <= "111" & STATE(0);		--
				end if;
			when "101"=> 
				ADDR_BUS(15 downto 2) <= x"00" & "000" & VDCNUM & "00";
				case IR(5 downto 4) is
					when "00" =>   ADDR_BUS(1 downto 0) <= "00";
					when "01" =>   ADDR_BUS(1 downto 0) <= "10";
					when others => ADDR_BUS(1 downto 0) <= "11";
				end case;
			when "110"=> 
				ADDR_BUS <= SH & X;
			when "111"=> 
				ADDR_BUS <= DH & Y;
			when others => null;
		end case;
	end process;
	
	A_OUT(12 downto 0) <= ADDR_BUS(12 downto 0);
	A_OUT(20 downto 13) <= x"FF" when MC.ADDR_BUS = "101" else MPR(to_integer(unsigned(ADDR_BUS(15 downto 13))));

	process(CLK, RST_N)
	begin
		if RST_N = '0' then
			CS_STATE <= '0';
		elsif rising_edge(CLK) then
			if SS_HOLD = '1' and SS_LOAD = '1' then
				CS_STATE <= SS_DATA(175);
			elsif EN = '1' then
				if IR(6 downto 0) = "1010100" and STATE = "00001" then
					CS_STATE <= IR(7);
				end if; 
			end if; 
		end if;
	end process;
	
	MCYCLE <= MC.MEM_CYCLE;
	
end rtl;
	