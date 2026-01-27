#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
import os
import time
import struct
import argparse
import serial
import binascii

# ===================== 配置 =====================
OTA_FRAME_HEADER = 0xABCD
OTA_ACK_HEADER_SEQ = b'\xAA\x55'

OTA_CMD_START = 0x01
OTA_CMD_DATA = 0x02
OTA_CMD_END = 0x03
OTA_CMD_VERIFY = 0x04

CHUNK_SIZE = 4096  # 4KB 每块
DEFAULT_BAUD = 2000000 

# ===================== 工具函数 =====================
def crc16_xmodem(data):
    """计算CRC16-XMODEM"""
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc <<= 1
            if crc & 0x10000:
                crc ^= 0x1021
    return crc & 0xFFFF

# ===================== OTA 类 =====================
class ESP32OTA:
    def __init__(self, port, baudrate):
        self.port = port
        self.baudrate = baudrate
        self.ser = None

    def connect(self):
        print(f"[*] 正在连接串口 {self.port} @ {self.baudrate}...")
        try:
            self.ser = serial.Serial(
                port=self.port,
                baudrate=self.baudrate,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=0.05,  # 非阻塞式读取 (Windows 上更流畅)
                xonxoff=False,
                rtscts=False,
                dsrdtr=False
            )
            
            # 复位设备
            self._reset_device()
            return True
        except Exception as e:
            print(f"[-] 连接失败: {e}")
            return False

    def close(self):
        if self.ser and self.ser.is_open:
            self.ser.close()

    def _reset_device(self):
        """复位ESP32"""
        if self.ser is None:
            return

        print("[*] 复位设备...")
        self.ser.dtr = False
        self.ser.rts = False # IO0=High, EN=High
        time.sleep(0.1)
        self.ser.rts = True   # EN = LOW (Reset)
        time.sleep(0.1)
        self.ser.rts = False  # EN = HIGH (Run)
        time.sleep(0.1)
        
        # 等待启动
        print("[*] 等待设备启动 (2秒)...")
        time.sleep(2.0)
        
        # 清空启动日志
        self.ser.reset_input_buffer()
        print("[*] 准备就绪")

    def send_frame(self, cmd, payload=b''):
        """发送协议帧"""
        if self.ser is None:
            return
            
        # 构造帧: [HEADER:2][CMD:1][LEN:2][RESERVED:9][DATA:N][CRC:2]
        header = struct.pack('>H', OTA_FRAME_HEADER)
        cmd_byte = struct.pack('B', cmd)
        length = struct.pack('>H', len(payload))
        reserved = b'\x00' * 9  # 9字节保留位
        
        frame_head = header + cmd_byte + length + reserved
        # 在计算CRC时，需要把 payload 也包含进去
        # 固件端计算CRC: crc16_xmodem(frame_buffer, frame_len - 2)
        # 也就是包含 Header + Cmd + Len + Reserved + Data
        
        data_to_sign = frame_head + payload
        crc = crc16_xmodem(data_to_sign)
        
        final_frame = data_to_sign + struct.pack('>H', crc)
        
        # Debug: 打印发送的十六进制
        # print(f"DEBUG SEND: {binascii.hexlify(final_frame)}")
        
        self.ser.write(final_frame)
        self.ser.flush()

    def receive_ack(self, timeout=2.0, verbose=False):
        """接收ACK"""
        if self.ser is None:
            return -1, "Serial not connected"

        start_time = time.time()
        buffer = b''
        
        while (time.time() - start_time) < timeout:
            if self.ser.in_waiting:
                buffer += self.ser.read(self.ser.in_waiting)
            
            # 扫描缓冲区寻找帧头 AA 55
            header_idx = buffer.find(OTA_ACK_HEADER_SEQ)
            
            if header_idx != -1:
                # 丢弃帧头前面的垃圾数据
                if header_idx > 0:
                    if verbose: 
                        print(f"丢弃垃圾数据: {buffer[:header_idx]}")
                    buffer = buffer[header_idx:]
                
                # 现在的 buffer 以 AA 55 开头
                # 需要至少 4 字节才能知道 msg 的长度 (Header(2) + Status(1) + MsgLen(1))
                if len(buffer) >= 4:
                    status = buffer[2]
                    msg_len = buffer[3]
                    
                    # 完整帧长度 = Header(2) + Status(1) + MsgLen(1) + Msg(N) + CRC(2)
                    total_len = 2 + 1 + 1 + msg_len + 2
                    
                    if len(buffer) >= total_len:
                        frame = buffer[:total_len]
                        
                        # 校验 CRC
                        # 校验范围: Header + Status + MsgLen + Msg
                        data_to_check = frame[:-2]
                        crc_recv = struct.unpack('>H', frame[-2:])[0]
                        crc_calc = crc16_xmodem(data_to_check)
                        
                        if crc_recv == crc_calc:
                            msg_data = frame[4:4+msg_len]
                            msg = msg_data.decode('utf-8', errors='replace')
                            return status, msg
                        else:
                            print(f"[-] CRC错误: 收到 {crc_recv:04X} 计算 {crc_calc:04X}")
                            # 移除这个坏帧头，继续搜后面的
                            buffer = buffer[2:]
                            continue
            
            time.sleep(0.001)  # 降低延迟，提高吞吐量
            
        # 超时
        if buffer and verbose and timeout > 0.5:
            # 尝试打印收到的内容
            try:
                print(f"[Device Output]: {buffer.decode('utf-8', errors='ignore')}")
            except:
                print(f"[Device Hex]: {binascii.hexlify(buffer)}")
                
        return -1, "Timeout"

    def sync(self):
        """尝试同步（使用VERIFY命令 Ping 设备）"""
        print("[*] 尝试连接设备 (Sync)...")
        
        # 尝试3次
        for i in range(3):
            self.send_frame(OTA_CMD_VERIFY)
            status, msg = self.receive_ack(timeout=1.0, verbose=True)
            
            if status == 0:
                print(f"[+] 同步成功！设备信息: {msg}")
                return True
            elif status > 0:
                # 设备回复了 Error，但也算是连上了
                print(f"[!] 设备已连接，但返回错误: {msg}")
                return True
            else:
                print(f"    尝试 {i+1}/3 超时...")
                time.sleep(0.5)
                
        return False

    def upload_file(self, file_path):
        if not os.path.exists(file_path):
            print(f"[-] 文件不存在: {file_path}")
            return False
            
        file_size = os.path.getsize(file_path)
        print(f"[+] 固件大小: {file_size} Bytes")
        
        with open(file_path, 'rb') as f:
            data = f.read()
            
        # 1. 发送 START
        print("[*] 发送 START 命令...")
        # START 负载是4字节的大端大小
        start_payload = struct.pack('>I', file_size)
        self.send_frame(OTA_CMD_START, start_payload)
        
        # 擦除 Flash 可能需要较长时间，给 5-10 秒
        status, msg = self.receive_ack(timeout=10.0, verbose=True)
        if status != 0:
            print(f"[-] START 失败: {msg}")
            return False
        
        print(f"[+] START 成功: {msg}")
        
        # 2. 发送 DATA
        print("[*] 开始发送数据...")
        offset = 0
        total_chunks = (file_size + CHUNK_SIZE - 1) // CHUNK_SIZE
        current_chunk = 0
        
        while offset < file_size:
            chunk = data[offset : offset + CHUNK_SIZE]
            self.send_frame(OTA_CMD_DATA, chunk)
            
            # 每个包的 ACK 超时短一点
            status, msg = self.receive_ack(timeout=1.0)
            if status != 0:
                print(f"\n[-] 数据块 {current_chunk} 失败: {msg}")
                return False
            
            offset += len(chunk)
            current_chunk += 1
            
            # 进度条
            percent = (offset * 100) // file_size
            bar_len = 40
            filled = (bar_len * percent) // 100
            bar = '█' * filled + '-' * (bar_len - filled)
            sys.stdout.write(f"\r[{bar}] {percent}% ({offset}/{file_size})")
            sys.stdout.flush()
            
        print("\n[+] 数据发送完成")
        
        # 3. 发送 END
        print("[*] 发送 END 命令...")
        self.send_frame(OTA_CMD_END)
        # 结束操作可能耗时
        status, msg = self.receive_ack(timeout=5.0, verbose=True)
        
        if status != 0:
            print(f"[-] END 失败: {msg}")
            return False
            
        print(f"[+] 升级成功！设备消息: {msg}")
        return True

# ===================== 主程序 =====================
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="ESP32 Python OTA Tool")
    parser.add_argument("--port", required=True, help="串口号 (如 COM3)")
    parser.add_argument("--file", required=True, help="固件 bin 文件路径")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD, help="波特率")
    
    args = parser.parse_args()
    
    ota = ESP32OTA(args.port, args.baud)
    
    try:
        if ota.connect():
            # 先尝试 Sync
            if ota.sync():
                # Sync 成功后稍微等一下再开始传
                time.sleep(0.5)
                ota.upload_file(args.file)
            else:
                print("[-] 无法与设备同步，请检查连线或固件是否支持 OTA")
    except KeyboardInterrupt:
        print("\n[-] 用户取消")
    finally:
        ota.close()
