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
    signal rd_ptr : unsigned(11 downto 0) := (others => '0');
    signal wr_ptr : unsigned(11 downto 0) := (others => '0');
    signal count  : unsigned(12 downto 0) := (others => '0');
    signal fifo_q : std_logic_vector(7 downto 0);
    signal do_read : std_logic;
    signal do_write : std_logic;
begin

    do_read <= rdreq when count /= 0 else '0';
    do_write <= wrreq when count /= 4096 else '0';

    RAM : entity work.dpram
    generic map (
        addr_width => 12,
        data_width => 8
    )
    port map (
        clock => wrclk,
        address_a => std_logic_vector(wr_ptr),
        data_a => data,
        enable_a => '1',
        wren_a => do_write,
        q_a => open,
        cs_a => '1',
        address_b => std_logic_vector(rd_ptr),
        data_b => (others => '0'),
        enable_b => '1',
        wren_b => '0',
        q_b => fifo_q,
        cs_b => '1'
    );

    -- The CD core supplies the same CLK on rdclk and wrclk.  Keeping one
    -- clocked process avoids the Intel dcfifo primitive while preserving the
    -- read behaviour expected by SCSI.vhd.
    process(wrclk, aclr)
    begin
        if aclr = '1' then
            rd_ptr <= (others => '0');
            wr_ptr <= (others => '0');
            count  <= (others => '0');
        elsif rising_edge(wrclk) then
            if do_write = '1' then
                wr_ptr <= wr_ptr + 1;
            end if;
            if do_read = '1' then
                rd_ptr <= rd_ptr + 1;
            end if;

            if do_write = '1' and do_read = '0' then
                count <= count + 1;
            elsif do_read = '1' and do_write = '0' then
                count <= count - 1;
            end if;
        end if;
    end process;

    q <= fifo_q;
    rdempty <= '1' when count = 0 else '0';
    wrfull  <= '1' when count = 4096 else '0';
end rtl;
