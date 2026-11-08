// OmniFlow node protocol v2 core (docs/DESIGN.md, "Universal board runtime").
//
// Plain C++ with no Arduino headers, no STL and no heap, so the same code runs
// on an Uno with 2 KB of RAM, on ESP32, BOARD_ESP8266 and Pico W, and natively on a
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
};

enum Mode : uint8_t { MODE_NONE, MODE_IN, MODE_IN_PULLUP, MODE_OUT, MODE_PWM, MODE_SERVO, MODE_ADC };

#ifdef __AVR__
const int MAX_PINS = 20;
const int MAX_WATCHES = 6;
const int MAX_ARGS = 6;
#else
const int MAX_PINS = 40;
const int MAX_WATCHES = 12;
const int MAX_ARGS = 8;
#endif
#ifndef OMNI_TEXT_MAX
#ifdef __AVR__
#define OMNI_TEXT_MAX 24
#else
#define OMNI_TEXT_MAX 72  // a Wi-Fi password is up to 63 characters
#endif
#endif

// One parsed command: a flat JSON object of string, number and boolean
// values. Parsing needs no heap.
struct Args {
  struct Field {
    char key[12];
    char text[OMNI_TEXT_MAX];
    long number;
    uint8_t kind;  // 1 string, 2 number, 3 bool, 4 null
  };
  Field fields[MAX_ARGS];
  int count;

  const Field* get(const char* key) const;
  const char* str(const char* key) const;
  bool num(const char* key, long* out) const;
};

bool parseArgs(const char* line, Args& args);
// Compares a command name with a literal made with OMNI_P.
bool named(const char* cmd, const char* literal);

// The pins a board offers, and what each can do. Pins it must keep for itself
// (flash, radio, USB serial) report no capabilities and are never offered.
struct BoardProfile {
  const char* name;
  uint8_t (*caps)(int pin);
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

// The hardware under the core. Values are already in protocol units:
// digital 0 or 1, analog and PWM in percent 0..100, servo in degrees.
class Hal {
 public:
  virtual ~Hal() {}
  virtual void setMode(int pin, Mode mode) = 0;
  virtual void writeDigital(int pin, int value) = 0;
  virtual int readDigital(int pin) = 0;
  virtual int readAnalogPercent(int pin) = 0;
  virtual void writePwmPercent(int pin, int percent) = 0;
  virtual void writeServo(int pin, int degrees) = 0;
  // 32 NEC frame bits; bit 0 is transmitted first.
  virtual void sendIr(uint32_t bitsInSendOrder) = 0;
  virtual bool hasIr() = 0;
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

  // Handles one command line and writes the reply line.
  void handleLine(const char* line, Out& out);
  // Checks watched pins and writes a pin.changed line for each change. Call often.
  void poll(Out& out);
  // The hello announcement, with the UDP port the board listens on.
  void hello(Out& out, int udpPort);
  void boot(Out& out);

  Mode modeOf(int pin) const { return (pin >= 0 && pin < MAX_PINS) ? modes_[pin] : MODE_NONE; }
  void setExtension(Extension* extension) { extension_ = extension; }
  const char* node() const { return node_; }
  void setNode(const char* node) { node_ = node; }

  void error(Out& out, long id, const char* message);
  void ack(Out& out, long id, const char* cmd, int pin, bool hasValue, int value);

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
  Watch* findWatch(int pin);

  const char* node_;
  const char* firmware_;
  const BoardProfile& board_;
  Hal& hal_;
  Extension* extension_ = 0;
  Mode modes_[MAX_PINS];
  int written_[MAX_PINS];
  Watch watches_[MAX_WATCHES];
};

}  // namespace omni

#endif
