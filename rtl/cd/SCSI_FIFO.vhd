library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity SCSI_FIFO is
    port (
        aclr   : in  std_logic := '0';
        data   : in  std_logic_vector(7 downto 0);
        rdclk  : in  std_logic;
        rdreq  : in  std_logic;
        wrclk  : in  std_logic;
        wrreq  : in  std_logic;
        q      : out std_logic_vector(7 downto 0);
        rdempty: out std_logic;
        wrfull : out std_logic
    );
end SCSI_FIFO;

architecture rtl of SCSI_FIFO is
    type mem_t is array (0 to 2047) of std_logic_vector(7 downto 0);
    signal mem : mem_t;
    signal rd_ptr : unsigned(10 downto 0) := (others => '0');
    signal wr_ptr : unsigned(10 downto 0) := (others => '0');
    signal count  : unsigned(11 downto 0) := (others => '0');
begin
    -- The CD core supplies the same CLK on rdclk and wrclk.  Keeping one
    -- clocked process avoids the Intel dcfifo primitive while preserving the
    -- show-ahead read behaviour expected by SCSI.vhd.
    process(wrclk, aclr)
        variable do_read  : boolean;
        variable do_write : boolean;
    begin
        if aclr = '1' then
            rd_ptr <= (others => '0');
            wr_ptr <= (others => '0');
            count  <= (others => '0');
        elsif rising_edge(wrclk) then
            do_read := (rdreq = '1' and count /= 0);
            do_write := (wrreq = '1' and count /= 2048);

            if do_write then
                mem(to_integer(wr_ptr)) <= data;
                wr_ptr <= wr_ptr + 1;
            end if;
            if do_read then
                rd_ptr <= rd_ptr + 1;
            end if;

            if do_write and not do_read then
                count <= count + 1;
            elsif do_read and not do_write then
                count <= count - 1;
            end if;
        end if;
    end process;

    q <= mem(to_integer(rd_ptr));
    rdempty <= '1' when count = 0 else '0';
    wrfull  <= '1' when count = 2048 else '0';
end rtl;
