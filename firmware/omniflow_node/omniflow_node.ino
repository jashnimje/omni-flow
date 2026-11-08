// OmniFlow node firmware: one sketch for ESP32, BOARD_ESP8266, Pico W and Uno.
//
// Flash it once and set it up from the app or `omni board setup` over USB:
// Wi-Fi, node name and IR pin are sent as commands and kept in flash, so no
// credentials are ever compiled in. The protocol lives in omni_core.cpp.
//
//   USB serial  115200 baud, one JSON command per line
//   Wi-Fi UDP   port 38950, replies go to the sender, events to whoever
//               last sent describe; hello broadcast to 38951 every 30 s;
//               mDNS service _omniflow._udp
#include <EEPROM.h>

#include "omni_core.h"

#if defined(ARDUINO_ARCH_ESP32)
#include <ESPmDNS.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#define OMNI_WIFI 1
#define OMNI_BOARD omni::BOARD_ESP32
#define OMNI_FW "omniflow-node/2 esp32"
#define OMNI_ADC_MAX 4095
#elif defined(ARDUINO_ARCH_ESP8266)
#include <ESP8266WiFi.h>
#include <ESP8266mDNS.h>
#include <Servo.h>
#include <WiFiUdp.h>
#define OMNI_WIFI 1
#define OMNI_BOARD omni::BOARD_ESP8266
#define OMNI_FW "omniflow-node/2 esp8266"
#define OMNI_ADC_MAX 1023
#elif defined(ARDUINO_RASPBERRY_PI_PICO_W)
#include <LEAmDNS.h>
#include <Servo.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#define OMNI_WIFI 1
#define OMNI_BOARD omni::BOARD_PICO_W
#define OMNI_FW "omniflow-node/2 pico_w"
#define OMNI_ADC_MAX 1023
#elif defined(ARDUINO_ARCH_AVR)
#include <Servo.h>
#define OMNI_WIFI 0
#define OMNI_BOARD omni::BOARD_UNO
#define OMNI_FW "omniflow-node/2 uno"
#define OMNI_ADC_MAX 1023
#else
#error "OmniFlow supports ESP32, BOARD_ESP8266, Pico W and AVR (Uno) boards"
#endif

using omni::Mode;

static const uint16_t UDP_PORT = 38950;
static const uint16_t HELLO_PORT = 38951;
static const unsigned long HELLO_EVERY_MS = 30000;
static const uint32_t SETTINGS_MAGIC = 0x4F4D4E32;  // "OMN2"

struct Settings {
  uint32_t magic;
#if OMNI_WIFI
  char ssid[33];
  char password[65];
#endif
  char node[24];
  int8_t irPin;
};

static Settings settings;

static void loadSettings() {
#if !defined(ARDUINO_ARCH_AVR)
  EEPROM.begin(sizeof(Settings));
#endif
  EEPROM.get(0, settings);
  if (settings.magic != SETTINGS_MAGIC) {
    memset(&settings, 0, sizeof(settings));
    settings.magic = SETTINGS_MAGIC;
    settings.irPin = -1;
  }
#if OMNI_WIFI
  settings.ssid[sizeof(settings.ssid) - 1] = 0;
  settings.password[sizeof(settings.password) - 1] = 0;
#endif
  settings.node[sizeof(settings.node) - 1] = 0;
}

static void saveSettings() {
  EEPROM.put(0, settings);
#if !defined(ARDUINO_ARCH_AVR)
  EEPROM.commit();
#endif
}

// ---------------------------------------------------------------- hardware

#if defined(ARDUINO_ARCH_ESP32)
// ESP32 has no Servo library in its core; LEDC drives both PWM and servos.
static const uint8_t PWM_BITS = 8;
static const uint8_t SERVO_BITS = 14;
#else
static Servo servos[omni::MAX_PINS];
#endif

class BoardHal : public omni::Hal {
 public:
  void setMode(int pin, Mode mode) override {
    release(pin);
    switch (mode) {
      case omni::MODE_IN: pinMode(pin, INPUT); break;
      case omni::MODE_IN_PULLUP: pinMode(pin, INPUT_PULLUP); break;
      case omni::MODE_OUT:
        pinMode(pin, OUTPUT);
        digitalWrite(pin, LOW);
        break;
      case omni::MODE_PWM:
#if defined(ARDUINO_ARCH_ESP32)
        ledcAttach(pin, 1000, PWM_BITS);
        ledcWrite(pin, 0);
#else
        pinMode(pin, OUTPUT);
        analogWrite(pin, 0);
#endif
        break;
      case omni::MODE_SERVO:
#if defined(ARDUINO_ARCH_ESP32)
        ledcAttach(pin, 50, SERVO_BITS);
#else
        servos[pin].attach(pin);
#endif
        break;
      case omni::MODE_ADC: pinMode(pin, INPUT); break;
      default: break;
    }
    modes[pin] = mode;
  }
  void writeDigital(int pin, int value) override { digitalWrite(pin, value ? HIGH : LOW); }
  int readDigital(int pin) override { return digitalRead(pin) == HIGH ? 1 : 0; }
  int readAnalogPercent(int pin) override {
    long raw = analogRead(pin);
    return (int)((raw * 100 + OMNI_ADC_MAX / 2) / OMNI_ADC_MAX);
  }
  void writePwmPercent(int pin, int percent) override {
#if defined(ARDUINO_ARCH_ESP32)
    ledcWrite(pin, (uint32_t)percent * ((1 << PWM_BITS) - 1) / 100);
#else
    analogWrite(pin, percent * 255 / 100);
#endif
  }
  void writeServo(int pin, int degrees) override {
#if defined(ARDUINO_ARCH_ESP32)
    // 500 to 2500 microseconds in a 20 ms frame.
    uint32_t us = 500 + (uint32_t)degrees * 2000 / 180;
    ledcWrite(pin, us * (1UL << SERVO_BITS) / 20000);
#else
    servos[pin].write(degrees);
#endif
  }
  bool hasIr() override { return settings.irPin >= 0; }
  void sendIr(uint32_t bits) override {
    int pin = settings.irPin;
    if (pin < 0) return;
    pinMode(pin, OUTPUT);
    mark(pin, 9000);
    space(4500);
    for (int i = 0; i < 32; i++) {
      mark(pin, 562);
      space((bits >> i) & 1 ? 1687 : 562);
    }
    mark(pin, 562);
  }
  unsigned long millis() override { return ::millis(); }

  Mode modes[omni::MAX_PINS] = {};

 private:
  void release(int pin) {
#if defined(ARDUINO_ARCH_ESP32)
    if (modes[pin] == omni::MODE_PWM || modes[pin] == omni::MODE_SERVO) ledcDetach(pin);
#else
    if (modes[pin] == omni::MODE_SERVO) servos[pin].detach();
#endif
  }
  // A 38 kHz carrier burst; IR receivers tolerate the few percent of drift
  // that bit-banging gives.
  static void mark(int pin, unsigned long us) {
    unsigned long start = micros();
    while (micros() - start < us) {
      digitalWrite(pin, HIGH);
      delayMicroseconds(9);
      digitalWrite(pin, LOW);
      delayMicroseconds(15);
    }
  }
  static void space(unsigned long us) {
    unsigned long start = micros();
    while (micros() - start < us) {
    }
  }
};

// ---------------------------------------------------------------- outputs

class SerialOut : public omni::Out {
 public:
  void write(const char* text) override { Serial.print(text); }
};

#if OMNI_WIFI
static WiFiUDP udp;

// Streams one line into one datagram, so a long describe needs no buffer.
class UdpOut : public omni::Out {
 public:
  IPAddress ip;
  uint16_t port = 0;
  bool open = false;
  void write(const char* text) override {
    if (!port) return;
    if (!open) open = udp.beginPacket(ip, port);
    if (open) udp.write((const uint8_t*)text, strlen(text));
  }
  void end() override {
    if (open) udp.endPacket();
    open = false;
  }
};

static UdpOut eventPeer;
#endif

class EventOut : public omni::Out {
 public:
  void write(const char* text) override {
    serial.write(text);
#if OMNI_WIFI
    eventPeer.write(text);
#endif
  }
  void end() override {
#if OMNI_WIFI
    eventPeer.end();
#endif
  }
  SerialOut serial;
};

// ---------------------------------------------------------------- setup commands

static BoardHal hal;
static omni::Core core("omniflow", OMNI_FW, OMNI_BOARD, hal);
static SerialOut serialOut;
static EventOut events;
static bool udpStarted = false;

static void defaultNodeName() {
  if (settings.node[0]) return;
#if OMNI_WIFI
  uint8_t mac[6];
  WiFi.macAddress(mac);
  snprintf(settings.node, sizeof(settings.node), "omni_%s_%02x%02x%02x", OMNI_BOARD.name, mac[3], mac[4], mac[5]);
#else
  snprintf(settings.node, sizeof(settings.node), "omni_%s", OMNI_BOARD.name);
#endif
}

static void startWifi() {
#if OMNI_WIFI
  if (!settings.ssid[0]) return;
  WiFi.mode(WIFI_STA);
  WiFi.begin(settings.ssid, settings.password);
#endif
}

static void wifiStatus(omni::Out& out, long id) {
  out.writeP(OMNI_P("{\"node\":\""));
  out.write(core.node());
  out.writeP(OMNI_P("\",\"event\":\"wifi\""));
#if OMNI_WIFI
  bool up = WiFi.status() == WL_CONNECTED;
  out.writeP(OMNI_P(",\"configured\":"));
  out.write(settings.ssid[0] ? "true" : "false");
  out.writeP(OMNI_P(",\"connected\":"));
  out.write(up ? "true" : "false");
  if (up) {
    char buf[64];
    IPAddress ip = WiFi.localIP();
    snprintf(buf, sizeof(buf), ",\"ip\":\"%u.%u.%u.%u\",\"port\":%u,\"rssi\":%d", ip[0], ip[1], ip[2], ip[3], UDP_PORT,
             (int)WiFi.RSSI());
    out.write(buf);
  }
#else
  out.writeP(OMNI_P(",\"configured\":false,\"connected\":false"));
#endif
  if (id >= 0) {
    char buf[24];
    snprintf(buf, sizeof(buf), ",\"id\":%ld", id);
    out.write(buf);
  }
  out.writeP(OMNI_P("}\n"));
  out.end();
}

class SetupCommands : public omni::Extension {
 public:
  bool handle(const char* cmd, const omni::Args& args, long id, omni::Out& out) override {
    if (omni::named(cmd, OMNI_P("wifi.set"))) {
#if OMNI_WIFI
      const char* ssid = args.str("ssid");
      const char* password = args.str("password");
      if (!ssid || !ssid[0] || strlen(ssid) >= sizeof(settings.ssid)) {
        core.error(out, id, OMNI_P("ssid is 1 to 32 characters"));
        return true;
      }
      if (password && strlen(password) >= sizeof(settings.password)) {
        core.error(out, id, OMNI_P("password is at most 64 characters"));
        return true;
      }
      strcpy(settings.ssid, ssid);
      strcpy(settings.password, password ? password : "");
      saveSettings();
      udpStarted = false;
      startWifi();
      core.ack(out, id, OMNI_P("wifi.set"), -1, false, 0);
#else
      core.error(out, id, OMNI_P("this board has no Wi-Fi"));
#endif
      return true;
    }
    if (omni::named(cmd, OMNI_P("wifi.status"))) {
      wifiStatus(out, id);
      return true;
    }
    if (omni::named(cmd, OMNI_P("node.set"))) {
      const char* name = args.str("name");
      if (!name || !name[0] || strlen(name) >= sizeof(settings.node)) {
        core.error(out, id, OMNI_P("name is 1 to 23 characters"));
        return true;
      }
      strcpy(settings.node, name);
      saveSettings();
      core.ack(out, id, OMNI_P("node.set"), -1, false, 0);
      return true;
    }
    if (omni::named(cmd, OMNI_P("ir.pin"))) {
      long pin;
      if (!args.num("pin", &pin) || (pin >= 0 && !(OMNI_BOARD.caps((int)pin) & omni::CAP_OUT))) {
        core.error(out, id, OMNI_P("pin must be an output pin, or -1 for none"));
        return true;
      }
      settings.irPin = (int8_t)(pin < 0 ? -1 : pin);
      saveSettings();
      core.ack(out, id, OMNI_P("ir.pin"), settings.irPin, false, 0);
      return true;
    }
    return false;
  }
};

static SetupCommands setupCommands;

// ---------------------------------------------------------------- main loop

#if defined(ARDUINO_ARCH_AVR)
static char line[96];
#else
static char line[200];
#endif
static size_t lineLen = 0;
static bool lineTooLong = false;

void setup() {
  Serial.begin(115200);
  loadSettings();
  defaultNodeName();
  core.setNode(settings.node);
  core.setExtension(&setupCommands);
  startWifi();
  core.boot(serialOut);
}

static void readSerial() {
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n') {
      line[lineLen] = 0;
      if (lineTooLong) {
        core.error(serialOut, -1, OMNI_P("line too long"));
      } else if (lineLen) {
        core.handleLine(line, serialOut);
      }
      lineLen = 0;
      lineTooLong = false;
    } else if (c != '\r') {
      if (lineLen < sizeof(line) - 1) {
        line[lineLen++] = c;
      } else {
        lineTooLong = true;
      }
    }
  }
}

#if OMNI_WIFI
static unsigned long lastHello = 0;

static void sendHello() {
  IPAddress ip = WiFi.localIP();
  IPAddress mask = WiFi.subnetMask();
  UdpOut hello;
  for (int i = 0; i < 4; i++) hello.ip[i] = ip[i] | (uint8_t)~mask[i];
  hello.port = HELLO_PORT;
  core.hello(hello, UDP_PORT);
  lastHello = millis();
}

static void serviceWifi() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (!udpStarted) {
    udp.begin(UDP_PORT);
    MDNS.begin(settings.node);
    MDNS.addService("omniflow", "udp", UDP_PORT);
    udpStarted = true;
    wifiStatus(serialOut, -1);
    sendHello();
  }
#if !defined(ARDUINO_ARCH_ESP32)
  MDNS.update();
#endif
  int size = udp.parsePacket();
  if (size > 0) {
    char buf[sizeof(line)];
    int n = udp.read((uint8_t*)buf, sizeof(buf) - 1);
    if (n > 0) {
      buf[n] = 0;
      while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = 0;
      UdpOut reply;
      reply.ip = udp.remoteIP();
      reply.port = udp.remotePort();
      if (strstr(buf, "\"describe\"")) {
        eventPeer.ip = reply.ip;
        eventPeer.port = reply.port;
      }
      core.handleLine(buf, reply);
    }
  }
  if (millis() - lastHello >= HELLO_EVERY_MS) sendHello();
}
#endif

void loop() {
  readSerial();
#if OMNI_WIFI
  serviceWifi();
#endif
  core.poll(events);
}
