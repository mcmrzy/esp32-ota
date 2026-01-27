import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_libserialport/flutter_libserialport.dart';

// ===================== 配置 =====================
const int OTA_FRAME_HEADER = 0xABCD;
final Uint8List OTA_ACK_HEADER_SEQ = Uint8List.fromList([0xAA, 0x55]);

const int OTA_CMD_START = 0x01;
const int OTA_CMD_DATA = 0x02;
const int OTA_CMD_END = 0x03;
const int OTA_CMD_VERIFY = 0x04;

const int CHUNK_SIZE = 4096; // 4KB 每块

// ===================== 工具函数 =====================
int crc16Xmodem(List<int> data) {
  int crc = 0;
  for (var byte in data) {
    crc ^= byte << 8;
    for (var i = 0; i < 8; i++) {
      crc <<= 1;
      if ((crc & 0x10000) != 0) {
        crc ^= 0x1021;
      }
    }
  }
  return crc & 0xFFFF;
}

class ESP32OTA {
  final String portName;
  final int baudRate;
  SerialPort? _port;
  bool _isConnected = false;

  Function(String) log;

  ESP32OTA(this.portName, this.baudRate, {required this.log});

  bool get isConnected => _isConnected;

  Future<bool> connect() async {
    log("[*] 正在连接串口 $portName @ $baudRate...");
    try {
      _port = SerialPort(portName);
      if (!_port!.openReadWrite()) {
        log("[-] 打开串口失败");
        return false;
      }

      final config = SerialPortConfig();
      config.baudRate = baudRate;
      config.bits = 8;
      config.stopBits = 1;
      config.parity = SerialPortParity.none;
      config.rts = SerialPortRts.off;
      config.dtr = SerialPortDtr.off;
      config.xonXoff = SerialPortXonXoff.disabled;
      
      _port!.config = config;
      _isConnected = true;

      // 复位设备
      await _resetDevice();
      return true;
    } catch (e) {
      log("[-] 连接异常: $e");
      disconnect();
      return false;
    }
  }

  void disconnect() {
    if (_port != null && _port!.isOpen) {
      _port!.close();
      _port!.dispose();
    }
    _port = null;
    _isConnected = false;
    log("[*] 断开连接");
  }

  Future<void> _resetDevice() async {
    if (_port == null) return;

    log("[*] 复位设备...");
    // DTR False, RTS False (IO0=High, EN=High)
    // In libserialport, setting RTS/DTR might require direct manipulation if config doesn't trigger immediately
    // But config.rts/dtr sets the state. 
    // We need to toggle them.
    
    // Initial state
    _port!.config.dtr = SerialPortDtr.off;
    _port!.config.rts = SerialPortRts.off;
    _port!.config = _port!.config; // Apply
    await Future.delayed(Duration(milliseconds: 100));

    // Reset: EN = LOW (RTS True)
    _port!.config.rts = SerialPortRts.on; 
    _port!.config = _port!.config;
    await Future.delayed(Duration(milliseconds: 100));

    // Run: EN = HIGH (RTS False)
    _port!.config.rts = SerialPortRts.off;
    _port!.config = _port!.config;
    await Future.delayed(Duration(milliseconds: 100));

    log("[*] 等待设备启动 (2秒)...");
    await Future.delayed(Duration(seconds: 2));

    // Clear buffer
    // _port!.flush(); // libserialport doesn't have explicit flush in the dart wrapper easily, but reading all helps
    while (_port!.bytesAvailable > 0) {
      _port!.read(_port!.bytesAvailable);
    }
    log("[*] 准备就绪");
  }

  void sendFrame(int cmd, [Uint8List? payload]) {
    if (_port == null) return;
    payload ??= Uint8List(0);

    // Header: 2 bytes
    final header = ByteData(2)..setUint16(0, OTA_FRAME_HEADER, Endian.big);
    
    // Cmd: 1 byte
    final cmdByte = Uint8List.fromList([cmd]);
    
    // Length: 2 bytes
    final length = ByteData(2)..setUint16(0, payload.length, Endian.big);
    
    // Reserved: 9 bytes
    final reserved = Uint8List(9); // Zeros

    final frameHead = Uint8List.fromList(
      header.buffer.asUint8List() + 
      cmdByte + 
      length.buffer.asUint8List() + 
      reserved
    );

    final dataToSign = Uint8List.fromList(frameHead + payload);
    final crc = crc16Xmodem(dataToSign);
    
    final crcBytes = ByteData(2)..setUint16(0, crc, Endian.big);
    
    final finalFrame = Uint8List.fromList(dataToSign + crcBytes.buffer.asUint8List());

    _port!.write(finalFrame);
    // flush is implicit usually or OS handled
  }

  Future<({int status, String msg})> receiveAck({double timeout = 2.0}) async {
    if (_port == null) return (status: -1, msg: "Serial not connected");

    final stopwatch = Stopwatch()..start();
    List<int> buffer = [];

    while (stopwatch.elapsedMilliseconds < timeout * 1000) {
      if (_port!.bytesAvailable > 0) {
        final data = _port!.read(_port!.bytesAvailable);
        buffer.addAll(data);
      }

      // 扫描帧头
      // Find OTA_ACK_HEADER_SEQ (AA 55)
      int headerIdx = -1;
      for (int i = 0; i < buffer.length - 1; i++) {
        if (buffer[i] == OTA_ACK_HEADER_SEQ[0] && buffer[i+1] == OTA_ACK_HEADER_SEQ[1]) {
          headerIdx = i;
          break;
        }
      }

      if (headerIdx != -1) {
        // Drop garbage
        if (headerIdx > 0) {
           buffer = buffer.sublist(headerIdx);
        }

        // Need at least 4 bytes: Header(2) + Status(1) + MsgLen(1)
        if (buffer.length >= 4) {
          final status = buffer[2];
          final msgLen = buffer[3];
          final totalLen = 2 + 1 + 1 + msgLen + 2;

          if (buffer.length >= totalLen) {
             final frame = Uint8List.fromList(buffer.sublist(0, totalLen));
             
             // Check CRC
             // Range: Header + Status + MsgLen + Msg (frame[:-2])
             final dataToCheck = frame.sublist(0, totalLen - 2);
             final crcRecv = ByteData.sublistView(frame, totalLen - 2, totalLen).getUint16(0, Endian.big);
             final crcCalc = crc16Xmodem(dataToCheck);

             if (crcRecv == crcCalc) {
               final msgData = frame.sublist(4, 4 + msgLen);
               final msg = utf8.decode(msgData, allowMalformed: true);
               return (status: status, msg: msg);
             } else {
               log("[-] CRC错误: 收到 ${crcRecv.toRadixString(16)} 计算 ${crcCalc.toRadixString(16)}");
               // Remove bad header and continue
               buffer = buffer.sublist(2);
               continue;
             }
          }
        }
      }

      await Future.delayed(Duration(milliseconds: 1));
    }

    return (status: -1, msg: "Timeout");
  }

  Future<bool> sync() async {
    log("[*] 尝试连接设备 (Sync)...");
    
    for (int i = 0; i < 3; i++) {
      sendFrame(OTA_CMD_VERIFY);
      final result = await receiveAck(timeout: 1.0);
      
      if (result.status == 0) {
        log("[+] 同步成功！设备信息: ${result.msg}");
        return true;
      } else if (result.status > 0) {
        log("[!] 设备已连接，但返回错误: ${result.msg}");
        return true;
      } else {
        log("    尝试 ${i+1}/3 超时...");
        await Future.delayed(Duration(milliseconds: 500));
      }
    }
    return false;
  }

  Future<bool> uploadFile(String filePath, Function(double) onProgress) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      log("[-] 文件不存在: $filePath");
      return false;
    }

    final fileSize = file.lengthSync();
    log("[+] 固件大小: $fileSize Bytes");
    final data = file.readAsBytesSync();

    // 1. Send START
    log("[*] 发送 START 命令...");
    final startPayload = ByteData(4)..setUint32(0, fileSize, Endian.big);
    sendFrame(OTA_CMD_START, startPayload.buffer.asUint8List());

    final startAck = await receiveAck(timeout: 10.0);
    if (startAck.status != 0) {
      log("[-] START 失败: ${startAck.msg}");
      return false;
    }
    log("[+] START 成功: ${startAck.msg}");

    // 2. Send DATA
    log("[*] 开始发送数据...");
    int offset = 0;
    int currentChunk = 0;

    while (offset < fileSize) {
      int end = offset + CHUNK_SIZE;
      if (end > fileSize) end = fileSize;
      
      final chunk = data.sublist(offset, end);
      sendFrame(OTA_CMD_DATA, chunk);

      final ack = await receiveAck(timeout: 1.0);
      if (ack.status != 0) {
        log("\n[-] 数据块 $currentChunk 失败: ${ack.msg}");
        return false;
      }

      offset += chunk.length;
      currentChunk++;
      
      onProgress(offset / fileSize);
    }

    log("\n[+] 数据发送完成");

    // 3. Send END
    log("[*] 发送 END 命令...");
    sendFrame(OTA_CMD_END);
    
    final endAck = await receiveAck(timeout: 5.0);
    if (endAck.status != 0) {
      log("[-] END 失败: ${endAck.msg}");
      return false;
    }

    log("[+] 升级成功！设备消息: ${endAck.msg}");
    return true;
  }
}
