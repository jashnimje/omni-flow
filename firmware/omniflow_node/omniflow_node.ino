// OmniFlow node firmware: one sketch for ESP32, ESP8266, Pico W and Uno.
//
// Flash it once and set it up with `omni board setup` over USB: Wi-Fi, node
// name and IR pin are sent as commands and kept in flash, so no credentials
// are ever compiled in. The protocol lives in omni_core.cpp.
//
//   USB serial  115200 baud, one JSON command per line
//   Wi-Fi UDP   port 38950, taken only from the board's own subnet; replies
//               go to the sender, events to up to 3 hosts that sent describe
//               in the last 90 s; hello broadcast to 38951 every 30 s;
//               mDNS service _omniflow._udp
#include <EEPROM.h>

#include "omni_core.h"

#if defined(ARDUINO_ARCH_ESP32) && defined(CONFIG_IDF_TARGET_ESP32)
#include <ESPmDNS.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <esp_mac.h>
#include <lwip/sockets.h>
#define OMNI_BOARD omni::BOARD_ESP32
#define OMNI_FW "omniflow-node/2 esp32"
#define OMNI_ADC_MAX 4095
#elif defined(ARDUINO_ARCH_ESP32)
#error "OmniFlow's ESP32 pin profile is for the classic ESP32, not the S2, S3, C3 or C6"
#elif defined(ARDUINO_ARCH_ESP8266)
#include <ESP8266WiFi.h>
#include <ESP8266mDNS.h>
#include <Servo.h>
#include <WiFiUdp.h>
#define OMNI_BOARD omni::BOARD_ESP8266
#define OMNI_FW "omniflow-node/2 esp8266"
#define OMNI_ADC_MAX 1023
#elif defined(ARDUINO_RASPBERRY_PI_PICO_W)
#include <LEAmDNS.h>
#include <Servo.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#define OMNI_BOARD omni::BOARD_PICO_W
#define OMNI_FW "omniflow-node/2 pico_w"
#define OMNI_ADC_MAX 1023
#elif defined(ARDUINO_AVR_UNO) || defined(ARDUINO_AVR_NANO)
#include <Servo.h>
#define OMNI_BOARD omni::BOARD_UNO
#define OMNI_FW "omniflow-node/2 uno"
#define OMNI_ADC_MAX 1023
#elif defined(ARDUINO_ARCH_AVR)
#error "OmniFlow's AVR pin profile is for the Uno and Nano (ATmega328P)"
#else
#error "OmniFlow supports ESP32, ESP8266, Pico W and Uno boards"
#endif

#define OMNI_WIFI OMNI_HAS_WIFI

using omni::Mode;

static const uint16_t UDP_PORT = 38950;
static const uint16_t HELLO_PORT = 38951;
static const unsigned long HELLO_EVERY_MS = 30000;
static const uint32_t SETTINGS_MAGIC = 0x4F4D4E32;  // "OMN2"

static omni::Settings settings;

static void loadSettings() {
#if !defined(ARDUINO_ARCH_AVR)
  EEPROM.begin(sizeof(settings));
#endif
  EEPROM.get(0, settings);
  if (settings.magic != SETTINGS_MAGIC) {
    memset(&settings, 0, sizeof(settings));
    settings.magic = SETTINGS_MAGIC;
    settings.irPin = -1;
  }
  omni::sanitizeSettings(settings);
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
// Servos come from a pool: the AVR library numbers them as they are
// constructed and drives only the first 12.
static const int SERVO_SLOTS = 12;
static Servo servos[SERVO_SLOTS];
static int8_t servoPins[SERVO_SLOTS];  // the pin each one drives, -1 when free
#endif

class BoardHal : public omni::Hal {
 public:
  BoardHal() {
    for (int i = 0; i < omni::MAX_PINS; i++) modes[i] = omni::MODE_NONE;
#if !defined(ARDUINO_ARCH_ESP32)
    for (int i = 0; i < SERVO_SLOTS; i++) servoPins[i] = -1;
#endif
  }
  bool setMode(int pin, Mode mode) override {
    if (!allowed(pin, mode)) return false;
    Mode old = modes[pin];
    release(pin);
    if (!apply(pin, mode)) {
      apply(pin, old);
      return false;
    }
    modes[pin] = mode;
#if defined(ARDUINO_ARCH_AVR)
    if (old == omni::MODE_SERVO && !servoCount()) restoreTimer1();
#endif
    return true;
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
    int slot = servoSlot(pin);
    if (slot >= 0) servos[slot].write(degrees);
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

 private:
  Mode modes[omni::MAX_PINS];

  bool allowed(int pin, Mode mode) {
#if defined(ARDUINO_ARCH_AVR)
    // The Servo library takes Timer1, which is also the PWM on 9 and 10.
    if (mode == omni::MODE_PWM && (pin == 9 || pin == 10) && servoCount()) return false;
    if (mode == omni::MODE_SERVO && (modes[9] == omni::MODE_PWM || modes[10] == omni::MODE_PWM)) return false;
#else
    (void)pin;
    (void)mode;
#endif
    return true;
  }
  // Returns false when no PWM or servo channel is free.
  bool apply(int pin, Mode mode) {
    switch (mode) {
      case omni::MODE_IN: pinMode(pin, INPUT); return true;
      case omni::MODE_IN_PULLUP: pinMode(pin, INPUT_PULLUP); return true;
      case omni::MODE_OUT:
        pinMode(pin, OUTPUT);
        digitalWrite(pin, LOW);
        return true;
      case omni::MODE_PWM:
#if defined(ARDUINO_ARCH_ESP32)
        if (!ledcAttach(pin, 1000, PWM_BITS)) return false;
        ledcWrite(pin, 0);
#else
        pinMode(pin, OUTPUT);
        analogWrite(pin, 0);
#endif
        return true;
      case omni::MODE_SERVO:
#if defined(ARDUINO_ARCH_ESP32)
        return ledcAttach(pin, 50, SERVO_BITS);
#else
        return attachServo(pin);
#endif
      default: pinMode(pin, INPUT); return true;  // MODE_ADC, and MODE_NONE releases the pin
    }
  }
  void release(int pin) {
#if defined(ARDUINO_ARCH_ESP32)
    if (modes[pin] == omni::MODE_PWM || modes[pin] == omni::MODE_SERVO) ledcDetach(pin);
#else
    if (modes[pin] == omni::MODE_PWM) analogWrite(pin, 0);
    int slot = servoSlot(pin);
    if (slot >= 0) {
      servos[slot].detach();
      servoPins[slot] = -1;
    }
#endif
  }
#if !defined(ARDUINO_ARCH_ESP32)
  static int servoSlot(int pin) {
    for (int i = 0; i < SERVO_SLOTS; i++) {
      if (servoPins[i] == pin) return i;
    }
    return -1;
  }
  static bool attachServo(int pin) {
    int slot = servoSlot(-1);
    if (slot < 0) return false;
    servos[slot].attach(pin);
    if (!servos[slot].attached()) return false;
    servoPins[slot] = (int8_t)pin;
    return true;
  }
#endif
#if defined(ARDUINO_ARCH_AVR)
  static int servoCount() {
    int n = 0;
    for (int i = 0; i < SERVO_SLOTS; i++) n += servoPins[i] >= 0;
    return n;
  }
  // Servo.detach leaves Timer1 set up for servos; put back what Arduino's
  // init() sets, so analogWrite on 9 and 10 works again.
  static void restoreTimer1() {
    TIMSK1 &= ~_BV(OCIE1A);
    TCCR1A = _BV(WGM10);
    TCCR1B = _BV(CS11) | _BV(CS10);
  }
#endif
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
#if defined(ARDUINO_ARCH_ESP32)
// NetworkUDP sends at most 1460 bytes per datagram and puts the rest in a
// second one, which would cut a long describe in two. This socket sends each
// line as one datagram and lets lwIP fragment it.
class BoardUdp {
 public:
  void begin(uint16_t port) {
    stop();
    fd_ = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd_ < 0) return;
    int yes = 1;
    setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(fd_, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));
    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(fd_, (struct sockaddr*)&addr, sizeof(addr)) != 0) return stop();
    fcntl(fd_, F_SETFL, O_NONBLOCK);
  }
  void stop() {
    if (fd_ >= 0) close(fd_);
    fd_ = -1;
  }
  // Returns the datagram's length, or 0 when none is waiting.
  int receive(char* buf, int size, IPAddress& ip, uint16_t& port) {
    if (fd_ < 0) return 0;
    struct sockaddr_in from = {};
    socklen_t fromLen = sizeof(from);
    int n = recvfrom(fd_, buf, size, MSG_DONTWAIT, (struct sockaddr*)&from, &fromLen);
    if (n <= 0 || from.sin_family != AF_INET) return 0;
    ip = IPAddress(from.sin_addr.s_addr);
    port = ntohs(from.sin_port);
    return n;
  }
  void send(const IPAddress& ip, uint16_t port, const char* data, size_t len) {
    if (fd_ < 0) return;
    struct sockaddr_in to = {};
    to.sin_family = AF_INET;
    to.sin_port = htons(port);
    to.sin_addr.s_addr = (uint32_t)ip;
    sendto(fd_, data, len, 0, (struct sockaddr*)&to, sizeof(to));
  }

 private:
  int fd_ = -1;
};
#else
class BoardUdp {
 public:
  void begin(uint16_t port) { udp_.begin(port); }
  void stop() { udp_.stop(); }
  int receive(char* buf, int size, IPAddress& ip, uint16_t& port) {
    if (udp_.parsePacket() <= 0) return 0;
    int n = udp_.read((uint8_t*)buf, size);
    ip = udp_.remoteIP();
    port = udp_.remotePort();
    return n > 0 ? n : 0;
  }
  void send(const IPAddress& ip, uint16_t port, const char* data, size_t len) {
    if (!udp_.beginPacket(ip, port)) return;
    udp_.write((const uint8_t*)data, len);
    udp_.endPacket();
  }

 private:
  WiFiUDP udp_;
};
#endif

static BoardUdp udp;

// Collects one line, then sends it as one datagram. Only one is written at a
// time, so they share the buffer; a describe with every pin set is about 2.4 KB.
static char udpLine[3072];

class UdpOut : public omni::Out {
 public:
  IPAddress ip;
  uint16_t port = 0;
  void write(const char* text) override {
    size_t n = strlen(text);
    if (len_ + n < sizeof(udpLine)) {
      memcpy(udpLine + len_, text, n);
      len_ += n;
    } else {
      overflow_ = true;
    }
  }
  void end() override {
    if (port && len_ && !overflow_) udp.send(ip, port, udpLine, len_);
    len_ = 0;
    overflow_ = false;
  }

 private:
  size_t len_ = 0;
  bool overflow_ = false;
};

// The hosts that get events. A hub sends describe on every hello, so one
// that missed three hellos is gone.
static const int MAX_PEERS = 3;
static const unsigned long PEER_TTL_MS = 3 * HELLO_EVERY_MS;

struct Peer {
  IPAddress ip;
  uint16_t port;  // 0 when the slot is free
  unsigned long seen;
};

static Peer peers[MAX_PEERS];

static void addPeer(IPAddress ip, uint16_t port) {
  Peer* slot = 0;
  for (int i = 0; i < MAX_PEERS; i++) {
    Peer& p = peers[i];
    if (p.port == port && p.ip == ip) {
      slot = &p;
      break;
    }
    if (!slot || !p.port || (slot->port && p.seen < slot->seen)) slot = &p;
  }
  slot->ip = ip;
  slot->port = port;
  slot->seen = millis();
}

static bool onSubnet(IPAddress ip) {
  IPAddress local = WiFi.localIP();
  IPAddress mask = WiFi.subnetMask();
  for (int i = 0; i < 4; i++) {
    if ((ip[i] & mask[i]) != (local[i] & mask[i])) return false;
  }
  return true;
}
#endif

// Events stream to serial and go to every peer as one datagram each, so the
// line is kept until it ends.
class EventOut : public omni::Out {
 public:
  void write(const char* text) override {
    serial.write(text);
#if OMNI_WIFI
    size_t n = strlen(text);
    if (len + n < sizeof(buf)) {
      memcpy(buf + len, text, n);
      len += n;
    } else {
      overflow = true;
    }
#endif
  }
  void end() override {
#if OMNI_WIFI
    unsigned long now = millis();
    for (int i = 0; i < MAX_PEERS; i++) {
      Peer& p = peers[i];
      if (!p.port) continue;
      if (now - p.seen > PEER_TTL_MS) {
        p.port = 0;
        continue;
      }
      if (!overflow) udp.send(p.ip, p.port, buf, len);
    }
    len = 0;
    overflow = false;
#endif
  }
  SerialOut serial;

 private:
#if OMNI_WIFI
  char buf[160];
  size_t len = 0;
  bool overflow = false;
#endif
};

// ---------------------------------------------------------------- setup commands

static BoardHal hal;
static omni::Core core("omniflow", OMNI_FW, OMNI_BOARD, hal);
static SerialOut serialOut;
static EventOut events;
#if OMNI_WIFI
static bool udpStarted = false;
#endif

#if defined(ARDUINO_RASPBERRY_PI_PICO_W)
// A Pico W join that fails is not retried by its core, so the sketch retries,
// backing off from 30 s to 5 min.
static const unsigned long WIFI_RETRY_FIRST_MS = 30000;
static const unsigned long WIFI_RETRY_MAX_MS = 300000;
static unsigned long wifiRetryMs = WIFI_RETRY_FIRST_MS;
static unsigned long wifiTriedAt = 0;
#endif

static void defaultNodeName() {
  if (settings.node[0]) return;
#if OMNI_WIFI
  uint8_t mac[6] = {0};
#if defined(ARDUINO_ARCH_ESP32)
  // WiFi.macAddress() writes nothing until the radio has started.
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
#else
  WiFi.macAddress(mac);
#endif
  snprintf(settings.node, sizeof(settings.node), "omni_%s_%02x%02x%02x", OMNI_BOARD.name, mac[3], mac[4], mac[5]);
#else
  snprintf(settings.node, sizeof(settings.node), "omni_%s", OMNI_BOARD.name);
#endif
  saveSettings();
}

static void startWifi() {
#if OMNI_WIFI
  if (!settings.ssid[0]) return;
  udpStarted = false;
  WiFi.mode(WIFI_STA);
#if defined(ARDUINO_RASPBERRY_PI_PICO_W)
  // begin() also waits for DHCP, for up to 30 s; this waits only for the join.
  WiFi.beginNoBlock(settings.ssid, settings.password);
  wifiTriedAt = millis();
#else
  WiFi.begin(settings.ssid, settings.password);
#endif
#endif
}

class BoardSetupHal : public omni::SetupHal {
 public:
  void saveSettings() override { ::saveSettings(); }
#if OMNI_WIFI
  void startWifi() override { ::startWifi(); }
  void stopWifi() override {
    if (udpStarted) udp.stop();
    udpStarted = false;
    for (int i = 0; i < MAX_PEERS; i++) peers[i].port = 0;
#if defined(ARDUINO_ARCH_ESP32)
    WiFi.disconnect(true, true);  // also erases the network the core keeps
#elif defined(ARDUINO_ARCH_ESP8266)
    WiFi.disconnect(true);
#else
    WiFi.disconnect();
#endif
  }
  bool wifiConnected() override { return WiFi.status() == WL_CONNECTED; }
  void localIp(uint8_t ip[4]) override {
    IPAddress local = WiFi.localIP();
    for (int i = 0; i < 4; i++) ip[i] = local[i];
  }
  int rssi() override { return (int)WiFi.RSSI(); }
#endif
};

static BoardSetupHal setupHal;
static omni::Setup setupCommands(core, settings, setupHal, UDP_PORT);

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
  core.setIrPin(settings.irPin);
  core.setExtension(&setupCommands);
  core.boot(serialOut);
  startWifi();
}

static void readSerial() {
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n') {
      line[lineLen] = 0;
      if (lineTooLong) {
        core.error(serialOut, -1, OMNI_P("line too long"));
      } else if (lineLen) {
        setupCommands.fromSerial = true;
        core.handleLine(line, serialOut);
        setupCommands.fromSerial = false;
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

#if defined(ARDUINO_RASPBERRY_PI_PICO_W)
static void retryWifi() {
  if (!settings.ssid[0]) return;
  if (WiFi.status() == WL_CONNECTED) {
    wifiRetryMs = WIFI_RETRY_FIRST_MS;
    return;
  }
  if (millis() - wifiTriedAt < wifiRetryMs) return;
  wifiRetryMs = wifiRetryMs * 2 > WIFI_RETRY_MAX_MS ? WIFI_RETRY_MAX_MS : wifiRetryMs * 2;
  startWifi();
}
#endif

static void serviceWifi() {
#if defined(ARDUINO_RASPBERRY_PI_PICO_W)
  retryWifi();
#endif
  if (WiFi.status() != WL_CONNECTED) return;
  if (!udpStarted) {
    udp.begin(UDP_PORT);
    MDNS.begin(settings.node);
    MDNS.addService("omniflow", "udp", UDP_PORT);
    udpStarted = true;
    setupCommands.wifiStatus(serialOut, -1);
    sendHello();
  }
#if !defined(ARDUINO_ARCH_ESP32)
  MDNS.update();
#endif
  char buf[sizeof(line)];
  UdpOut reply;
  int n = udp.receive(buf, sizeof(buf) - 1, reply.ip, reply.port);
  if (n > 0 && onSubnet(reply.ip)) {
    buf[n] = 0;
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = 0;
    if (core.handleLine(buf, reply)) addPeer(reply.ip, reply.port);
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
