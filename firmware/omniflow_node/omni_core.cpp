#include "omni_core.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

namespace omni {

void Out::writeP(const char* text) {
#ifdef __AVR__
  char buf[17];
  uint8_t n = 0;
  char c;
  while ((c = (char)pgm_read_byte(text++))) {
    buf[n++] = c;
    if (n == sizeof(buf) - 1) {
      buf[n] = 0;
      write(buf);
      n = 0;
    }
  }
  buf[n] = 0;
  if (n) write(buf);
#else
  write(text);
#endif
}

bool named(const char* cmd, const char* literal) {
#ifdef __AVR__
  return strcmp_P(cmd, literal) == 0;
#else
  return strcmp(cmd, literal) == 0;
#endif
}

// ---------------------------------------------------------------- profiles

static const uint8_t DIGITAL = CAP_IN | CAP_PULLUP | CAP_OUT;

uint8_t esp32Caps(int pin) {
  if (pin < 0 || pin > 39) return 0;
  if (pin == 1 || pin == 3) return 0;  // UART0, the USB serial port
  if (pin >= 6 && pin <= 11) return 0;  // SPI flash
  if (pin == 20 || pin == 24 || (pin >= 28 && pin <= 31)) return 0;  // not bonded out
  if (pin >= 34) return CAP_IN | CAP_ADC;  // input only, with no pull-up
  uint8_t caps = DIGITAL | CAP_PWM | CAP_SERVO;
  // Only ADC1 (32 to 39) reads while Wi-Fi is on; ADC2 pins are left digital.
  if (pin == 32 || pin == 33) caps |= CAP_ADC;
  return caps;
}

uint8_t esp8266Caps(int pin) {
  if (pin == 17) return CAP_ADC;  // A0 is analog only
  if (pin == 0 || pin == 2 || pin == 4 || pin == 5 || (pin >= 12 && pin <= 15)) return DIGITAL | CAP_PWM | CAP_SERVO;
  if (pin == 16) return CAP_IN | CAP_OUT;  // a pull-down, not a pull-up
  return 0;  // 1 and 3 are serial, 6 to 11 are flash
}

uint8_t picoWCaps(int pin) {
  if (pin >= 0 && pin <= 22) return DIGITAL | CAP_PWM | CAP_SERVO;
  if (pin >= 26 && pin <= 28) return DIGITAL | CAP_PWM | CAP_SERVO | CAP_ADC;
  return 0;  // 23, 24, 25 and 29 belong to the CYW43 radio
}

uint8_t unoCaps(int pin) {
  if (pin >= 2 && pin <= 13) {
    bool pwm = pin == 3 || pin == 5 || pin == 6 || pin == 9 || pin == 10 || pin == 11;
    // The Servo library takes Timer1, which is the PWM on 9 and 10.
    bool servo = pin != 9 && pin != 10;
    return DIGITAL | (servo ? CAP_SERVO : 0) | (pwm ? CAP_PWM : 0);
  }
  if (pin >= 14 && pin <= 19) return DIGITAL | CAP_ADC;  // A0..A5
  return 0;  // 0 and 1 are the USB serial port
}

uint8_t hostCaps(int pin) {
  if (pin >= 0 && pin <= 15) return DIGITAL | CAP_PWM | CAP_SERVO;
  if (pin >= 16 && pin <= 19) return CAP_IN | CAP_PULLUP | CAP_ADC;
  return 0;
}

const BoardProfile BOARD_ESP32 = {"esp32", esp32Caps};
const BoardProfile BOARD_ESP8266 = {"esp8266", esp8266Caps};
const BoardProfile BOARD_PICO_W = {"pico_w", picoWCaps};
const BoardProfile BOARD_UNO = {"uno", unoCaps};
const BoardProfile BOARD_HOST = {"host", hostCaps};

// ---------------------------------------------------------------- NEC

uint32_t necFrame(uint16_t address, uint8_t command) {
  uint8_t b0, b1;
  if (address <= 0xFF) {
    b0 = (uint8_t)address;
    b1 = (uint8_t)(~address & 0xFF);
  } else {
    b0 = (uint8_t)(address & 0xFF);
    b1 = (uint8_t)(address >> 8);
  }
  return (uint32_t)b0 | ((uint32_t)b1 << 8) | ((uint32_t)command << 16) | ((uint32_t)(uint8_t)~command << 24);
}

uint32_t necFromMsbCode(uint32_t code) {
  uint32_t out = 0;
  for (int i = 0; i < 32; i++) {
    if (code & (1UL << (31 - i))) out |= (1UL << i);
  }
  return out;
}

// ---------------------------------------------------------------- tiny JSON

const Args::Field* Args::get(const char* key) const {
  for (int i = 0; i < count; i++) {
    if (strcmp(fields[i].key, key) == 0) return &fields[i];
  }
  return 0;
}

const char* Args::str(const char* key) const {
  const Field* f = get(key);
  return (f && f->kind == 1) ? f->text : 0;
}

bool Args::num(const char* key, long* out) const {
  const Field* f = get(key);
  if (!f || (f->kind != 2 && f->kind != 3)) return false;
  *out = f->number;
  return true;
}

static const char* skipSpace(const char* p) {
  while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
  return p;
}

static char unescape(char c) {
  switch (c) {
    case '"':
    case '\\':
    case '/': return c;
    case 'n': return '\n';
    case 't': return '\t';
    case 'r': return '\r';
    case 'b': return '\b';
    case 'f': return '\f';
    default: return 0;  // \u and anything else
  }
}

// OMNI_P cannot be used outside a function, so these are flash arrays.
#ifdef __AVR__
#define OMNI_FLASH PROGMEM
#else
#define OMNI_FLASH
#endif
static const char NOT_JSON[] OMNI_FLASH = "not a JSON command";
static const char TOO_LONG[] OMNI_FLASH = "value too long";

// Reads a JSON string into dest. On failure returns 0 and sets *error.
static const char* readString(const char* p, char* dest, int size, const char** error) {
  *error = NOT_JSON;
  if (*p != '"') return 0;
  p++;
  int n = 0;
  while (*p && *p != '"') {
    char c = *p++;
    if (c == '\\') {
      c = unescape(*p++);
      if (!c) return 0;
    }
    if (n >= size - 1) {
      *error = TOO_LONG;
      return 0;
    }
    dest[n++] = c;
  }
  if (*p != '"') return 0;
  dest[n] = 0;
  return p + 1;
}

// The id of a line that did not parse, so its error still answers the request.
static long scanId(const char* line) {
  const char* p = strstr(line, "\"id\"");
  if (!p) return -1;
  p = skipSpace(p + 4);
  if (*p != ':') return -1;
  p = skipSpace(p + 1);
  if (*p < '0' || *p > '9') return -1;
  return strtol(p, 0, 10);
}

const char* parseArgs(const char* line, Args& msg) {
  msg.count = 0;
  const char* p = skipSpace(line);
  if (*p != '{') return NOT_JSON;
  p = skipSpace(p + 1);
  if (*p == '}') return 0;
  const char* error;
  while (*p) {
    if (msg.count >= (int)(sizeof(msg.fields) / sizeof(msg.fields[0]))) return NOT_JSON;
    Args::Field& f = msg.fields[msg.count];
    f.kind = 0;
    f.number = 0;
    f.text[0] = 0;
    p = readString(p, f.key, sizeof(f.key), &error);
    if (!p) return error;
    p = skipSpace(p);
    if (*p != ':') return NOT_JSON;
    p = skipSpace(p + 1);
    if (*p == '"') {
      p = readString(p, f.text, sizeof(f.text), &error);
      if (!p) return error;
      f.kind = 1;
    } else if (strncmp(p, "true", 4) == 0) {
      f.kind = 3;
      f.number = 1;
      p += 4;
    } else if (strncmp(p, "false", 5) == 0) {
      f.kind = 3;
      f.number = 0;
      p += 5;
    } else if (strncmp(p, "null", 4) == 0) {
      f.kind = 4;
      p += 4;
    } else if (*p == '-' || (*p >= '0' && *p <= '9')) {
      char* end;
      f.number = strtol(p, &end, 10);
      if (*end == '.') {  // keep the integer part of a decimal
        end++;
        while (*end >= '0' && *end <= '9') end++;
      }
      p = end;
      f.kind = 2;
    } else {
      return NOT_JSON;  // nested objects and arrays are not commands
    }
    msg.count++;
    p = skipSpace(p);
    if (*p == ',') {
      p = skipSpace(p + 1);
      continue;
    }
    return *p == '}' ? 0 : NOT_JSON;
  }
  return NOT_JSON;
}

// ---------------------------------------------------------------- core

static const char* modeName(Mode m) {
  switch (m) {
    case MODE_IN: return "in";
    case MODE_IN_PULLUP: return "in_pullup";
    case MODE_OUT: return "out";
    case MODE_PWM: return "pwm";
    case MODE_SERVO: return "servo";
    case MODE_ADC: return "adc";
    default: return "none";
  }
}

static bool modeFromName(const char* name, Mode* out) {
  static const Mode all[] = {MODE_NONE, MODE_IN, MODE_IN_PULLUP, MODE_OUT, MODE_PWM, MODE_SERVO, MODE_ADC};
  for (unsigned i = 0; i < sizeof(all) / sizeof(all[0]); i++) {
    if (strcmp(name, modeName(all[i])) == 0) {
      *out = all[i];
      return true;
    }
  }
  return false;
}

static bool isInput(Mode m) { return m == MODE_IN || m == MODE_IN_PULLUP || m == MODE_ADC; }

static uint8_t capFor(Mode m) {
  switch (m) {
    case MODE_IN: return CAP_IN;
    case MODE_IN_PULLUP: return CAP_PULLUP;
    case MODE_OUT: return CAP_OUT;
    case MODE_PWM: return CAP_PWM;
    case MODE_SERVO: return CAP_SERVO;
    case MODE_ADC: return CAP_ADC;
    default: return 0;
  }
}

Core::Core(const char* node, const char* firmware, const BoardProfile& board, Hal& hal)
    : node_(node), firmware_(firmware), board_(board), hal_(hal) {
  for (int i = 0; i < MAX_PINS; i++) {
    modes_[i] = MODE_NONE;
    written_[i] = 0;
  }
  for (int i = 0; i < MAX_WATCHES; i++) watches_[i].pin = -1;
}

static void writeHead(Out& out, const char* node, const char* event) {
  out.writeP(OMNI_P("{\"node\":\""));
  out.write(node);
  out.writeP(OMNI_P("\",\"event\":\""));
  out.writeP(event);
  out.writeP(OMNI_P("\""));
}

static void writeNumber(Out& out, const char* key, long value) {
  char buf[40];
  snprintf(buf, sizeof(buf), ",\"%s\":%ld", key, value);
  out.write(buf);
}

static void writeId(Out& out, long id) {
  if (id >= 0) writeNumber(out, "id", id);
}

void Core::error(Out& out, long id, const char* message) {
  writeHead(out, node_, OMNI_P("error"));
  out.writeP(OMNI_P(",\"message\":\""));
  out.writeP(message);
  out.writeP(OMNI_P("\""));
  writeId(out, id);
  out.writeP(OMNI_P("}\n"));
  out.end();
}

void Core::ack(Out& out, long id, const char* cmd, int pin, bool hasValue, int value) {
  writeHead(out, node_, OMNI_P("ack"));
  out.writeP(OMNI_P(",\"cmd\":\""));
  out.writeP(cmd);
  out.writeP(OMNI_P("\""));
  if (pin >= 0) writeNumber(out, "pin", pin);
  if (hasValue) writeNumber(out, "value", value);
  writeId(out, id);
  out.writeP(OMNI_P("}\n"));
  out.end();
}

void Core::describe(Out& out, long id) {
  writeHead(out, node_, OMNI_P("describe"));
  out.writeP(OMNI_P(",\"proto\":2,\"fw\":\""));
  out.write(firmware_);
  out.writeP(OMNI_P("\",\"board\":\""));
  out.write(board_.name);
  out.writeP(OMNI_P("\",\"ir\":"));
  out.write(hal_.hasIr() ? "true" : "false");
  writeNumber(out, "watches", MAX_WATCHES);
  out.writeP(OMNI_P(",\"pins\":["));
  bool first = true;
  for (int pin = 0; pin < MAX_PINS; pin++) {
    uint8_t caps = capsOf(pin);
    if (!caps) continue;
    char buf[24];
    snprintf(buf, sizeof(buf), "%s{\"pin\":%d,\"caps\":[", first ? "" : ",", pin);
    out.write(buf);
    first = false;
    bool firstCap = true;
    static const struct {
      uint8_t cap;
      const char* name;
    } names[] = {{CAP_IN, "in"},       {CAP_PULLUP, "pullup"}, {CAP_OUT, "out"},
                 {CAP_PWM, "pwm"},     {CAP_SERVO, "servo"},   {CAP_ADC, "adc"}};
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
      if (!(caps & names[i].cap)) continue;
      out.write(firstCap ? "\"" : ",\"");
      out.write(names[i].name);
      out.writeP(OMNI_P("\""));
      firstCap = false;
    }
    out.writeP(OMNI_P("]}"));
  }
  // The pins that have a mode now, so the host can plan its setup.
  out.writeP(OMNI_P("],\"set\":["));
  first = true;
  for (int pin = 0; pin < MAX_PINS; pin++) {
    if (modes_[pin] == MODE_NONE) continue;
    char buf[32];
    snprintf(buf, sizeof(buf), "%s{\"pin\":%d,\"mode\":\"", first ? "" : ",", pin);
    out.write(buf);
    out.write(modeName(modes_[pin]));
    out.writeP(OMNI_P("\"}"));
    first = false;
  }
  out.writeP(OMNI_P("]"));
  writeId(out, id);
  out.writeP(OMNI_P("}\n"));
  out.end();
}

uint8_t Core::capsOf(int pin) const {
  if (pin < 0 || pin >= MAX_PINS || pin == irPin_) return 0;
  return board_.caps(pin);
}

void Core::hello(Out& out, int udpPort) {
  writeHead(out, node_, OMNI_P("hello"));
  out.writeP(OMNI_P(",\"proto\":2,\"board\":\""));
  out.write(board_.name);
  out.writeP(OMNI_P("\""));
  writeNumber(out, "port", udpPort);
  writeNumber(out, "up", (long)(hal_.millis() / 1000));
  // How many pins have a mode: 0 after a reboot tells the host to set them up.
  int set = 0;
  for (int i = 0; i < MAX_PINS; i++) {
    if (modes_[i] != MODE_NONE) set++;
  }
  writeNumber(out, "set", set);
  out.writeP(OMNI_P("}\n"));
  out.end();
}

void Core::boot(Out& out) {
  writeHead(out, node_, OMNI_P("boot"));
  out.writeP(OMNI_P(",\"proto\":2,\"fw\":\""));
  out.write(firmware_);
  out.writeP(OMNI_P("\"}\n"));
  out.end();
}

int Core::readValue(int pin) {
  switch (modes_[pin]) {
    case MODE_ADC: return hal_.readAnalogPercent(pin);
    case MODE_OUT:
    case MODE_PWM:
    case MODE_SERVO: return written_[pin];
    default: return hal_.readDigital(pin);
  }
}

Core::Watch* Core::findWatch(int pin) {
  for (int i = 0; i < MAX_WATCHES; i++) {
    if (watches_[i].pin == pin) return &watches_[i];
  }
  return 0;
}

void Core::setPinMode(Out& out, long id, int pin, Mode mode) {
  // Setting the mode a pin already has changes nothing, so the host can
  // re-send its whole pin setup at any time without switching outputs off.
  if (modes_[pin] == mode) return ack(out, id, OMNI_P("pin.mode"), pin, false, 0);
  if (!hal_.setMode(pin, mode)) {
    // The hardware is back in the old mode, so put its output level back too.
    if (modes_[pin] == MODE_OUT) hal_.writeDigital(pin, written_[pin]);
    if (modes_[pin] == MODE_PWM) hal_.writePwmPercent(pin, written_[pin]);
    if (modes_[pin] == MODE_SERVO) hal_.writeServo(pin, written_[pin]);
    return error(out, id, OMNI_P("no free PWM or servo channel"));
  }
  // A watch reads the pin, so it only stays while the pin is an input.
  if (!isInput(mode)) {
    Watch* w = findWatch(pin);
    if (w) w->pin = -1;
  }
  modes_[pin] = mode;
  written_[pin] = 0;
  // Every board's servo starts at the middle, the same as Servo.attach.
  if (mode == MODE_SERVO) {
    written_[pin] = 90;
    hal_.writeServo(pin, 90);
  }
  ack(out, id, OMNI_P("pin.mode"), pin, false, 0);
}

bool Core::handleLine(const char* line, Out& out) {
  Args m;
  const char* parseError = parseArgs(line, m);
  if (parseError) {
    error(out, scanId(line), parseError);
    return false;
  }
  long id = -1;
  m.num("id", &id);
  const char* cmd = m.str("cmd");
  if (!cmd) {
    error(out, id, OMNI_P("missing cmd"));
    return false;
  }

  if (named(cmd, OMNI_P("describe"))) {
    describe(out, id);
    return true;
  }

  if (named(cmd, OMNI_P("ir.send")) || named(cmd, OMNI_P("ir_send"))) {
    if (!hal_.hasIr()) {
      error(out, id, OMNI_P("this board has no IR output"));
      return false;
    }
    const char* protocol = m.str("protocol");
    long address, command;
    if (protocol && !named(protocol, OMNI_P("NEC"))) {
      error(out, id, OMNI_P("only NEC is supported"));
    } else if (m.num("address", &address) && m.num("command", &command)) {
      if (address < 0 || address > 0xFFFF || command < 0 || command > 0xFF) {
        error(out, id, OMNI_P("address or command out of range"));
      } else {
        hal_.sendIr(necFrame((uint16_t)address, (uint8_t)command));
        ack(out, id, OMNI_P("ir.send"), -1, false, 0);
      }
    } else if (m.str("hex")) {
      char* end;
      unsigned long code = strtoul(m.str("hex"), &end, 16);
      if (*end) {
        error(out, id, OMNI_P("hex is not a number"));
      } else {
        hal_.sendIr(necFromMsbCode((uint32_t)code));
        ack(out, id, OMNI_P("ir.send"), -1, false, 0);
      }
    } else {
      error(out, id, OMNI_P("needs address and command, or hex"));
    }
    return false;
  }

  // A pin is a whole number on the board; true, 2.5 or "4" is not a pin.
  const Args::Field* pinField = m.get("pin");
  bool hasPin = pinField && pinField->kind == 2 && pinField->number >= 0 && pinField->number < MAX_PINS;
  int pin = hasPin ? (int)pinField->number : -1;
  uint8_t caps = hasPin ? capsOf(pin) : 0;
  if (hasPin && !caps) hasPin = false;

  if (named(cmd, OMNI_P("pin.mode"))) {
    if (!hasPin) {
      error(out, id, OMNI_P("pin not available on this board"));
      return false;
    }
    Mode mode;
    const char* name = m.str("mode");
    if (!name || !modeFromName(name, &mode)) {
      error(out, id, OMNI_P("mode must be none, in, in_pullup, out, pwm, servo or adc"));
    } else if (mode != MODE_NONE && !(caps & capFor(mode))) {
      error(out, id, OMNI_P("this pin cannot do that mode"));
    } else {
      setPinMode(out, id, pin, mode);
    }
    return false;
  }

  // v1 compatibility: gpio_write sets the pin to output on first use.
  if (named(cmd, OMNI_P("gpio_write"))) {
    if (!hasPin || !(caps & CAP_OUT)) {
      error(out, id, OMNI_P("pin not allowed"));
      return false;
    }
    if (modes_[pin] != MODE_OUT) {
      Watch* w = findWatch(pin);
      if (w) w->pin = -1;
      modes_[pin] = MODE_OUT;
      hal_.setMode(pin, MODE_OUT);
    }
    cmd = "pin.write";
  }

  if (named(cmd, OMNI_P("pin.write")) || named(cmd, OMNI_P("pwm.write")) || named(cmd, OMNI_P("servo.write"))) {
    long value;
    if (!hasPin) {
      error(out, id, OMNI_P("pin not available on this board"));
    } else if (!m.num("value", &value)) {
      error(out, id, OMNI_P("needs value"));
    } else if (named(cmd, OMNI_P("pin.write"))) {
      if (modes_[pin] != MODE_OUT) {
        error(out, id, OMNI_P("set pin.mode out first"));
      } else {
        int v = value ? 1 : 0;
        hal_.writeDigital(pin, v);
        written_[pin] = v;
        ack(out, id, OMNI_P("pin.write"), pin, true, v);
      }
    } else if (named(cmd, OMNI_P("pwm.write"))) {
      if (modes_[pin] != MODE_PWM) {
        error(out, id, OMNI_P("set pin.mode pwm first"));
      } else if (value < 0 || value > 100) {
        error(out, id, OMNI_P("pwm value is 0 to 100"));
      } else {
        hal_.writePwmPercent(pin, (int)value);
        written_[pin] = (int)value;
        ack(out, id, OMNI_P("pwm.write"), pin, true, (int)value);
      }
    } else if (modes_[pin] != MODE_SERVO) {
      error(out, id, OMNI_P("set pin.mode servo first"));
    } else if (value < 0 || value > 180) {
      error(out, id, OMNI_P("servo value is 0 to 180"));
    } else {
      hal_.writeServo(pin, (int)value);
      written_[pin] = (int)value;
      ack(out, id, OMNI_P("servo.write"), pin, true, (int)value);
    }
    return false;
  }

  if (named(cmd, OMNI_P("pin.read"))) {
    if (!hasPin) {
      error(out, id, OMNI_P("pin not available on this board"));
    } else if (modes_[pin] == MODE_NONE) {
      error(out, id, OMNI_P("set pin.mode first"));
    } else {
      ack(out, id, OMNI_P("pin.read"), pin, true, readValue(pin));
    }
    return false;
  }

  if (named(cmd, OMNI_P("pin.watch"))) {
    if (!hasPin) {
      error(out, id, OMNI_P("pin not available on this board"));
      return false;
    }
    Watch* w = findWatch(pin);
    long off = 0;
    // Turning a watch off works in any mode, so a stale watch can always go.
    if (m.num("off", &off) && off) {
      if (w) w->pin = -1;
      ack(out, id, OMNI_P("pin.watch"), pin, false, 0);
      return false;
    }
    if (!isInput(modes_[pin])) {
      error(out, id, OMNI_P("only input pins can be watched"));
      return false;
    }
    if (!w) w = findWatch(-1);
    if (!w) {
      error(out, id, OMNI_P("too many watched pins"));
      return false;
    }
    long ms = 50, delta = 0;
    m.num("ms", &ms);
    m.num("delta", &delta);
    if (ms < 10) ms = 10;
    if (ms > 60000) ms = 60000;
    if (delta < 0) delta = 0;
    w->pin = (int8_t)pin;
    w->ms = (uint16_t)ms;
    w->delta = (uint8_t)(delta > 100 ? 100 : delta);
    w->last = readValue(pin);
    w->checked = hal_.millis();
    ack(out, id, OMNI_P("pin.watch"), pin, true, w->last);
    return false;
  }

  if (!extension_ || !extension_->handle(cmd, m, id, out)) error(out, id, OMNI_P("unknown command"));
  return false;
}

void Core::poll(Out& out) {
  unsigned long now = hal_.millis();
  for (int i = 0; i < MAX_WATCHES; i++) {
    Watch& w = watches_[i];
    if (w.pin < 0 || now - w.checked < w.ms) continue;
    w.checked = now;
    int value = readValue(w.pin);
    int diff = value - w.last;
    if (diff < 0) diff = -diff;
    if (value == w.last || diff <= w.delta) continue;
    w.last = value;
    writeHead(out, node_, OMNI_P("pin.changed"));
    writeNumber(out, "pin", w.pin);
    writeNumber(out, "value", value);
    out.writeP(OMNI_P("}\n"));
    out.end();
  }
}

// ---------------------------------------------------------------- setup

bool validNodeName(const char* name) {
  if (!name || name[0] < 'a' || name[0] > 'z') return false;
  int n = 0;
  for (; name[n]; n++) {
    char c = name[n];
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) return false;
  }
  return n < (int)sizeof(Settings::node);
}

void sanitizeSettings(Settings& settings) {
#if OMNI_HAS_WIFI
  settings.ssid[sizeof(settings.ssid) - 1] = 0;
  settings.password[sizeof(settings.password) - 1] = 0;
#endif
  settings.node[sizeof(settings.node) - 1] = 0;
  if (!validNodeName(settings.node)) settings.node[0] = 0;
}

#if OMNI_HAS_WIFI
// Empty for an open network, a WPA passphrase of 8 to 63 characters, or a
// raw 64-digit hex key. Anything else the radio refuses later, silently.
static bool validPassword(const char* password) {
  size_t n = strlen(password);
  if (n == 0) return true;
  if (n < 8 || n > 64) return false;
  if (n < 64) return true;
  for (size_t i = 0; i < n; i++) {
    if (!isxdigit((unsigned char)password[i])) return false;
  }
  return true;
}
#endif

Setup::Setup(Core& core, Settings& settings, SetupHal& hal, int udpPort)
    : core_(core), settings_(settings), hal_(hal), udpPort_(udpPort) {}

void Setup::wifiStatus(Out& out, long id) {
  writeHead(out, core_.node(), OMNI_P("wifi"));
#if OMNI_HAS_WIFI
  bool up = hal_.wifiConnected();
  out.writeP(OMNI_P(",\"configured\":"));
  out.write(settings_.ssid[0] ? "true" : "false");
  out.writeP(OMNI_P(",\"connected\":"));
  out.write(up ? "true" : "false");
  if (up) {
    uint8_t ip[4];
    hal_.localIp(ip);
    char buf[64];
    snprintf(buf, sizeof(buf), ",\"ip\":\"%u.%u.%u.%u\",\"port\":%d,\"rssi\":%d", ip[0], ip[1], ip[2], ip[3], udpPort_,
             hal_.rssi());
    out.write(buf);
  }
#else
  out.writeP(OMNI_P(",\"configured\":false,\"connected\":false"));
#endif
  hal_.statusExtra(out);
  writeId(out, id);
  out.writeP(OMNI_P("}\n"));
  out.end();
}

bool Setup::handle(const char* cmd, const Args& args, long id, Out& out) {
  bool wifiSet = named(cmd, OMNI_P("wifi.set"));
  bool wifiClear = named(cmd, OMNI_P("wifi.clear"));
  bool nodeSet = named(cmd, OMNI_P("node.set"));
  bool irPin = named(cmd, OMNI_P("ir.pin"));
  if ((wifiSet || wifiClear || nodeSet || irPin) && !fromSerial) {
    core_.error(out, id, OMNI_P("setup commands are only taken over USB"));
    return true;
  }
  if (wifiSet || wifiClear) {
#if OMNI_HAS_WIFI
    if (wifiClear) {
      settings_.ssid[0] = 0;
      settings_.password[0] = 0;
      hal_.saveSettings();
      core_.ack(out, id, OMNI_P("wifi.clear"), -1, false, 0);
      hal_.stopWifi();
      return true;
    }
    const char* ssid = args.str("ssid");
    const char* password = args.str("password");
    if (!password) password = "";
    if (!ssid || !ssid[0] || strlen(ssid) >= sizeof(settings_.ssid)) {
      core_.error(out, id, OMNI_P("ssid is 1 to 32 characters"));
    } else if (!validPassword(password)) {
      core_.error(out, id, OMNI_P("password is empty, 8 to 63 characters, or 64 hex digits"));
    } else {
      strcpy(settings_.ssid, ssid);
      strcpy(settings_.password, password);
      hal_.saveSettings();
      // Joining can block for seconds on some boards, so the ack goes first.
      core_.ack(out, id, OMNI_P("wifi.set"), -1, false, 0);
      hal_.startWifi();
    }
#else
    core_.error(out, id, OMNI_P("this board has no Wi-Fi"));
#endif
    return true;
  }
  if (named(cmd, OMNI_P("wifi.status"))) {
    wifiStatus(out, id);
    return true;
  }
  if (nodeSet) {
    const char* name = args.str("name");
    if (!validNodeName(name)) {
      core_.error(out, id, OMNI_P("name is lower case letters, digits, _ and -"));
      return true;
    }
    strcpy(settings_.node, name);
    core_.setNode(settings_.node);
    hal_.saveSettings();
    core_.ack(out, id, OMNI_P("node.set"), -1, false, 0);
    return true;
  }
  if (irPin) {
    const Args::Field* f = args.get("pin");
    long pin = f && f->kind == 2 ? f->number : -2;
    bool none = pin == -1;
    if (!none && (pin < 0 || pin >= MAX_PINS || !(core_.board().caps((int)pin) & CAP_OUT))) {
      core_.error(out, id, OMNI_P("pin must be an output pin, or -1 for none"));
    } else if (!none && core_.modeOf((int)pin) != MODE_NONE) {
      core_.error(out, id, OMNI_P("that pin has a mode, set pin.mode none first"));
    } else {
      settings_.irPin = (int8_t)pin;
      core_.setIrPin(settings_.irPin);
      hal_.saveSettings();
      core_.ack(out, id, OMNI_P("ir.pin"), settings_.irPin, false, 0);
    }
    return true;
  }
  return false;
}

}  // namespace omni
