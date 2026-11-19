// OmniFlow node protocol v2 core (docs/engine-design.md, "Universal board runtime").
//
// Plain C++ with no Arduino headers, no STL and no heap, so the same code runs
// on an Uno with 2 KB of RAM, on ESP32, ESP8266 and Pico W, and natively on a
// desktop as the virtual board the engine tests talk to.
#ifndef OMNI_CORE_H
#define OMNI_CORE_H

#include <stdint.h>

// String literals stay in flash on AVR, where RAM is only 2 KB.
#ifdef __AVR__
#include <avr/pgmspace.h>
#define OMNI_P(s) PSTR(s)
#else
#define OMNI_P(s) (s)
#endif

namespace omni {

// Pin capabilities, as a bitmask.
enum Cap : uint8_t {
  CAP_IN = 1,
  CAP_OUT = 2,
  CAP_PWM = 4,
  CAP_SERVO = 8,
  CAP_ADC = 16,
  CAP_PULLUP = 32,  // an internal pull-up, for in_pullup
};

enum Mode : uint8_t { MODE_NONE, MODE_IN, MODE_IN_PULLUP, MODE_OUT, MODE_PWM, MODE_SERVO, MODE_ADC };

// OMNI_SMALL builds the AVR limits natively, so the tests cover them too.
#if defined(__AVR__) || defined(OMNI_SMALL)
const int MAX_PINS = 20;
const int MAX_WATCHES = 6;
const int MAX_ARGS = 6;
#else
const int MAX_PINS = 40;
const int MAX_WATCHES = 12;
const int MAX_ARGS = 8;
#endif
#ifndef OMNI_TEXT_MAX
#if defined(__AVR__) || defined(OMNI_SMALL)
#define OMNI_TEXT_MAX 24
#else
#define OMNI_TEXT_MAX 72  // a Wi-Fi password is up to 64 characters
#endif
#endif
// The Uno is the only supported board without Wi-Fi.
#ifdef __AVR__
#define OMNI_HAS_WIFI 0
#else
#define OMNI_HAS_WIFI 1
#endif
// The PN532 needs Wire, whose buffers take 182 bytes of the Uno's RAM, more
// than it has left, so the Uno takes only the RC522 (SPI, no buffers).
#ifndef OMNI_HAS_PN532
#if defined(__AVR__) || defined(OMNI_SMALL)
#define OMNI_HAS_PN532 0
#else
#define OMNI_HAS_PN532 1
#endif
#endif

// One parsed command: a JSON object of string, number and boolean values.
// One nested object of those is flattened, so {"pins":{"ss":10}} is the
// field "pins.ss". Parsing needs no heap.
struct Args {
  struct Field {
    char key[12];
    char text[OMNI_TEXT_MAX];  // a string, or a number as it was written
    long number;
    uint8_t kind;  // 1 string, 2 number, 3 bool, 4 null
  };
  Field fields[MAX_ARGS];
  int count;

  const Field* get(const char* key) const;
  const char* str(const char* key) const;
  bool num(const char* key, long* out) const;
  // A whole number 0 to 4294967295, which a long cannot hold on 32-bit boards.
  bool u32(const char* key, uint32_t* out) const;
};

// Returns 0 when the line parsed, otherwise the error to report (an OMNI_P literal).
const char* parseArgs(const char* line, Args& args);
// Compares a command name with a literal made with OMNI_P.
bool named(const char* cmd, const char* literal);

// The pins a board offers, and what each can do. Pins it must keep for itself
// (flash, radio, USB serial) report no capabilities and are never offered.
struct BoardProfile {
  const char* name;
  uint8_t (*caps)(int pin);
  // The hardware SPI bus: sck, miso, mosi, then the pin an SPI master must
  // keep as an output (the Uno's 10), or -1.
  int8_t spi[4];
  int8_t i2c[2];  // sda, scl of the default Wire bus
};

uint8_t esp32Caps(int pin);
uint8_t esp8266Caps(int pin);
uint8_t picoWCaps(int pin);
uint8_t unoCaps(int pin);
uint8_t hostCaps(int pin);

extern const BoardProfile BOARD_ESP32;
extern const BoardProfile BOARD_ESP8266;
extern const BoardProfile BOARD_PICO_W;
extern const BoardProfile BOARD_UNO;
extern const BoardProfile BOARD_HOST;

// A 433 MHz on-off keyed protocol from RCSwitch's table, in pulse lengths.
struct RfProtocol {
  uint8_t number;
  uint16_t pulseUs;
  uint8_t syncHigh, syncLow, zeroHigh, zeroLow, oneHigh, oneLow;
};

// The hardware under the core. Values are already in protocol units:
// digital 0 or 1, analog and PWM in percent 0..100, servo in degrees.
class Hal {
 public:
  virtual ~Hal() {}
  // Returns false, with the pin left in its old mode, when no PWM or servo
  // channel is free. MODE_NONE releases the pin to a plain input. For
  // MODE_OUT, level (0 or 1) is driven from the instant the pin is an output.
  virtual bool setMode(int pin, Mode mode, int level) = 0;
  virtual void writeDigital(int pin, int value) = 0;
  virtual int readDigital(int pin) = 0;
  virtual int readAnalogPercent(int pin) = 0;
  virtual void writePwmPercent(int pin, int percent) = 0;
  virtual void writeServo(int pin, int degrees) = 0;
  // 32 NEC frame bits; bit 0 is transmitted first. necPulse gives the timing.
  virtual void sendIr(uint32_t bitsInSendOrder) = 0;
  virtual bool hasIr() = 0;
  // Sends the code repeat times on the RF pin; rfPulse gives the timing.
  virtual void sendRf(const RfProtocol& protocol, uint32_t code, uint8_t bits, uint8_t repeat) = 0;
  virtual bool hasRf() = 0;
  // Starts the NFC reader of that type (a PeriphType) on its pins, or stops
  // the one running for PERIPH_NONE.
  virtual void startNfc(uint8_t type, int ss, int rst) {
    (void)type;
    (void)ss;
    (void)rst;
  }
  // Starts or carries on one read of the tag in the field. Returns its UID
  // length, 0 for no tag, or -1 while the read is still going.
  virtual int pollNfc(uint8_t* uid) {
    (void)uid;
    return 0;
  }
  virtual unsigned long millis() = 0;
};

// Where the core writes its JSON lines (serial, a UDP reply, stdout).
class Out {
 public:
  virtual ~Out() {}
  virtual void write(const char* text) = 0;
  // Writes a literal made with OMNI_P.
  void writeP(const char* text);
  // Called after each complete line.
  virtual void end() {}
};

// NEC frame bits in send order for an 8-bit address (inverted copy follows)
// or a 16-bit extended address, and an 8-bit command. Each byte goes least
// significant bit first.
uint32_t necFrame(uint16_t address, uint8_t command);
// A 32-bit code written most significant bit first (old IRremote, LIRC).
uint32_t necFromMsbCode(uint32_t code);

// An NEC frame is NEC_PULSES carrier marks, each followed by a space: the
// 9 ms header, the 32 bits, then the stop mark, whose space is 0.
const int NEC_PULSES = 34;
const uint32_t IR_CARRIER_HZ = 38000;
void necPulse(uint32_t bitsInSendOrder, int i, uint16_t* markUs, uint16_t* spaceUs);

// RCSwitch protocols 1 to 3. Returns false for any other number.
bool rfProtocol(long number, RfProtocol* out);
// One RF frame is bits + 1 pulses, each high then low: the code most
// significant bit first, then the sync, as RCSwitch::send does it.
void rfPulse(const RfProtocol& protocol, uint32_t code, uint8_t bits, int i, uint16_t* highUs, uint16_t* lowUs);
const int RF_MAX_REPEAT = 20;

// ---------------------------------------------------------------- peripherals

enum PeriphType : uint8_t { PERIPH_NONE, PERIPH_IR, PERIPH_RF, PERIPH_NFC_RC522, PERIPH_NFC_PN532 };
// Returns PERIPH_NONE for a name this firmware does not know.
PeriphType periphFromName(const char* name);
const char* periphName(PeriphType type);
// Whether this build can drive the type (the Uno has no PN532).
bool periphBuiltIn(PeriphType type);

// What is attached to which pins. -1 is no pin. The field order is part of
// the stored Settings layout.
struct Periphs {
  int8_t irPin;
  int8_t rfPin;
  uint8_t nfc;  // PERIPH_NONE, PERIPH_NFC_RC522 or PERIPH_NFC_PN532
  int8_t nfcSs;  // RC522 chip select
  int8_t nfcRst;  // RC522 reset, or -1 for a soft reset
};

// Why a set of peripherals cannot be on these pins.
enum PeriphIssue : uint8_t {
  PERIPH_OK,
  PERIPH_NOT_OUTPUT,  // a pin of its own is not an output pin on this board
  PERIPH_SAME_PIN,  // two of its own pins, or its pin and its bus, are one pin
  PERIPH_IS_IR,  // a pin it takes is the IR pin
  PERIPH_IS_RF,
  PERIPH_IS_NFC,
};
// Checks every pin that changed takes (its own and its bus) against the
// board and against the other peripherals in p.
PeriphIssue checkPeriphs(const Periphs& p, const BoardProfile& board, PeriphType changed);
// Lists the pins type takes in p, its bus included, into pins (room for 6).
int periphPins(const Periphs& p, const BoardProfile& board, PeriphType type, int8_t* pins);

// ISO 14443-3 CRC_A, low byte first, as it goes on air.
void crcA(const uint8_t* data, int len, uint8_t out[2]);

// One ISO 14443 type A exchange through a reader (the RC522). txLastBits is
// how many bits of the last byte to send, 0 for all 8. Returns the bytes
// received, or -1 for a timeout, a collision or a bad frame.
class NfcTransceiver {
 public:
  virtual ~NfcTransceiver() {}
  virtual int transceive(const uint8_t* tx, int txLen, uint8_t txLastBits, uint8_t* rx, int rxMax) = 0;
};
const int NFC_UID_MAX = 10;
// Wakes the tag in the field (WUPA, so a halted one answers too), runs the
// cascade levels to read its UID, then halts it, so the next wake-up finds
// it again while it stays. Returns the UID length (4, 7 or 10), or 0.
int readTypeAUid(NfcTransceiver& reader, uint8_t uid[NFC_UID_MAX]);

#if OMNI_HAS_PN532
// PN532 host frames (user manual 6.2.1): preamble, start code, length and
// its checksum, TFI D4, the command and its data, data checksum, postamble.
// out needs len + 8 bytes. Returns the frame length.
int pn532Frame(const uint8_t* command, int len, uint8_t* out);
// Checks a frame from the PN532 and finds its payload after TFI D5. Returns
// the payload length, or -1.
int pn532Payload(const uint8_t* frame, int len, const uint8_t** payload);
// The UID in an InListPassiveTarget (4A) reply payload, or 0 for no target.
int pn532ListedUid(const uint8_t* payload, int len, uint8_t uid[NFC_UID_MAX]);
#endif

// Reports a tag once per presentation: a new UID at once, the same UID again
// only after the reader has not seen it for goneMs.
class NfcDebounce {
 public:
  explicit NfcDebounce(uint16_t goneMs) : goneMs_(goneMs) {}
  // Call with every UID the reader reads. Returns true to report it.
  bool seen(const uint8_t* uid, int len, unsigned long now);

 private:
  uint16_t goneMs_;
  uint8_t uid_[NFC_UID_MAX];
  uint8_t len_ = 0;
  unsigned long seen_ = 0;
};
const unsigned long NFC_POLL_MS = 100;
const uint16_t NFC_GONE_MS = 1000;

class Out;

// Board-specific commands (Wi-Fi setup, flash settings) that the core does
// not know. Returns false to leave the command to the core.
class Extension {
 public:
  virtual ~Extension() {}
  virtual bool handle(const char* cmd, const Args& args, long id, Out& out) = 0;
};

class Core {
 public:
  Core(const char* node, const char* firmware, const BoardProfile& board, Hal& hal);

  // Handles one command line and writes the reply line. Returns true for a
  // describe, which is how a host on the network subscribes to events.
  bool handleLine(const char* line, Out& out);
  // Checks watched pins and writes a pin.changed line for each change. Call often.
  void poll(Out& out);
  // The hello announcement, with the UDP port the board listens on.
  void hello(Out& out, int udpPort);
  void boot(Out& out);

  Mode modeOf(int pin) const { return (pin >= 0 && pin < MAX_PINS) ? modes_[pin] : MODE_NONE; }
  void setExtension(Extension* extension) { extension_ = extension; }
  const char* node() const { return node_; }
  void setNode(const char* node) { node_ = node; }
  const BoardProfile& board() const { return board_; }
  // The peripherals' pins (and an NFC reader's bus) are kept from pin
  // commands and describe. Starts or stops the NFC reader when it changed.
  void setPeriphs(const Periphs& periphs);
  const Periphs& periphs() const { return periph_; }
  int irPin() const { return periph_.irPin; }
  int rfPin() const { return periph_.rfPin; }
  // What a pin offers to pin commands: its profile capabilities, or none for
  // a peripheral's pins and pins outside the profile.
  uint8_t capsOf(int pin) const;

  void error(Out& out, long id, const char* message);
  void ack(Out& out, long id, const char* cmd, int pin, bool hasValue, int value);
  void periphAck(Out& out, long id, const char* cmd, PeriphType type);

 private:
  struct Watch {
    int8_t pin;
    uint16_t ms;
    uint8_t delta;
    int last;
    unsigned long checked;
  };

  int readValue(int pin);
  void describe(Out& out, long id);
  void describePeriphs(Out& out);
  void pollNfc(Out& out, unsigned long now);
  Watch* findWatch(int pin);
  void setPinMode(Out& out, long id, int pin, Mode mode, int level);
  void sendRf(Out& out, long id, const Args& m);
  bool levelWritten(int pin) const { return (levelSet_[pin / 8] >> (pin % 8)) & 1; }
  void markWritten(int pin, bool on);

  const char* node_;
  const char* firmware_;
  const BoardProfile& board_;
  Hal& hal_;
  Extension* extension_ = 0;
  Periphs periph_ = {-1, -1, PERIPH_NONE, -1, -1};
  bool nfcBusy_ = false;
  unsigned long nfcPolled_ = 0;
  NfcDebounce nfcSeen_{NFC_GONE_MS};
  Mode modes_[MAX_PINS];
  int written_[MAX_PINS];
  // Set once pin.write has chosen an output's level, so a resent pin.mode
  // out with a value no longer changes it.
  uint8_t levelSet_[(MAX_PINS + 7) / 8];
  Watch watches_[MAX_WATCHES];
};

// What the board keeps in flash. The field order is the stored layout.
struct Settings {
  uint32_t magic;
#if OMNI_HAS_WIFI
  char ssid[33];
  char password[65];
#endif
  char node[24];
  // Version 2 stored only irPin, version 3 added rfPin, version 4 the NFC
  // reader. Older ones are read with the later fields set to none.
  Periphs periph;
};

// A node name is a lower case letter, then up to 22 lower case letters,
// digits, _ or -, so it never needs escaping in JSON.
bool validNodeName(const char* name);
// Makes settings read back from flash safe to use: terminates the strings,
// drops a node name that is not valid, so the board builds its default again,
// and drops each peripheral the board cannot take, in the order IR, RF, NFC.
void sanitizeSettings(Settings& settings, const BoardProfile& board);

// What the setup commands need from the board.
class SetupHal {
 public:
  virtual ~SetupHal() {}
  virtual void saveSettings() = 0;
#if OMNI_HAS_WIFI
  virtual void startWifi() = 0;
  virtual void stopWifi() = 0;
  virtual bool wifiConnected() = 0;
  virtual void localIp(uint8_t ip[4]) = 0;
  virtual int rssi() = 0;
#endif
  // node.set changed the name, which mDNS announces.
  virtual void nodeRenamed() {}
  // Lets the virtual board add test-only fields to wifi.status.
  virtual void statusExtra(Out&) {}
};

// The setup commands: wifi.set, wifi.clear, wifi.status, node.set,
// periph.set, periph.clear, and ir.pin and rf.pin, the older form of
// periph.set for IR and RF. All but wifi.status change how the board joins
// the network, what it is called or what is wired to it, so they are taken
// only from USB serial, never from the Wi-Fi.
class Setup : public Extension {
 public:
  Setup(Core& core, Settings& settings, SetupHal& hal, int udpPort);
  bool handle(const char* cmd, const Args& args, long id, Out& out) override;
  void wifiStatus(Out& out, long id);
  // Set while a serial line is handled.
  bool fromSerial = false;

 private:
  void setPeriph(Out& out, long id, const Args& args, bool alias, PeriphType type);
  void clearPeriph(Out& out, long id, PeriphType type);
  void applyPeriphs(Out& out, long id, const Periphs& next, PeriphType changed, bool alias);

  Core& core_;
  Settings& settings_;
  SetupHal& hal_;
  int udpPort_;
};

#if OMNI_HAS_WIFI
// When a board on Wi-Fi (re)starts its network services and says hello. A
// hello goes out the moment the board joins or rejoins, then every period.
class Link {
 public:
  enum Action : uint8_t {
    START_UDP = 1,  // (re)open the UDP socket and report wifi.status
    START_MDNS = 2,  // restart mDNS under the current node name
    HELLO = 4,
  };
  explicit Link(unsigned long helloEveryMs) : every_(helloEveryMs) {}
  // Call every loop with whether Wi-Fi is up. Returns Action bits to do now.
  uint8_t update(bool connected, unsigned long now);
  // The node name changed: restart mDNS and say hello at once.
  void renamed() { renamed_ = true; }
  // Wi-Fi was set up again or cleared: the next join starts everything again.
  void reset() { up_ = false; }

 private:
  unsigned long every_;
  unsigned long lastHello_ = 0;
  bool up_ = false;
  bool renamed_ = false;
};
#endif

}  // namespace omni

#endif
