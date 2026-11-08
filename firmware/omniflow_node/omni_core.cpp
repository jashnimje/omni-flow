#include "omni_core.h"

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

uint8_t esp32Caps(int pin) {
  if (pin < 0 || pin > 39) return 0;
  if (pin >= 6 && pin <= 11) return 0;  // SPI flash
  if (pin == 20 || pin == 24 || (pin >= 28 && pin <= 31)) return 0;  // not bonded out
  if (pin >= 34) return CAP_IN | CAP_ADC;  // input only
  uint8_t caps = CAP_IN | CAP_OUT | CAP_PWM | CAP_SERVO;
  // Only ADC1 (32 to 39) reads while Wi-Fi is on; ADC2 pins are left digital.
  if (pin == 32 || pin == 33) caps |= CAP_ADC;
  return caps;
}

uint8_t esp8266Caps(int pin) {
  if (pin == 17) return CAP_IN | CAP_ADC;  // A0
  if (pin == 0 || pin == 2 || pin == 4 || pin == 5 || (pin >= 12 && pin <= 15)) return CAP_IN | CAP_OUT | CAP_PWM | CAP_SERVO;
  if (pin == 16) return CAP_IN | CAP_OUT;
  return 0;  // 1 and 3 are serial, 6 to 11 are flash
}

uint8_t picoWCaps(int pin) {
  if (pin >= 0 && pin <= 22) return CAP_IN | CAP_OUT | CAP_PWM | CAP_SERVO;
  if (pin >= 26 && pin <= 28) return CAP_IN | CAP_OUT | CAP_PWM | CAP_SERVO | CAP_ADC;
  return 0;  // 23, 24, 25 and 29 belong to the CYW43 radio
}

uint8_t unoCaps(int pin) {
  if (pin >= 2 && pin <= 13) {
    bool pwm = pin == 3 || pin == 5 || pin == 6 || pin == 9 || pin == 10 || pin == 11;
    return CAP_IN | CAP_OUT | CAP_SERVO | (pwm ? CAP_PWM : 0);
  }
  if (pin >= 14 && pin <= 19) return CAP_IN | CAP_OUT | CAP_ADC;  // A0..A5
  return 0;  // 0 and 1 are the USB serial port
}

uint8_t hostCaps(int pin) {
  if (pin >= 0 && pin <= 15) return CAP_IN | CAP_OUT | CAP_PWM | CAP_SERVO;
  if (pin >= 16 && pin <= 19) return CAP_IN | CAP_ADC;
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

static const char* readString(const char* p, char* dest, int size) {
  if (*p != '"') return 0;
  p++;
  int n = 0;
  while (*p && *p != '"') {
    char c = *p++;
    if (c == '\\' && *p) c = *p++;
    if (n < size - 1) dest[n++] = c;
  }
  if (*p != '"') return 0;
  dest[n] = 0;
  return p + 1;
}

bool parseArgs(const char* line, Args& msg) {
  msg.count = 0;
  const char* p = skipSpace(line);
  if (*p != '{') return false;
  p = skipSpace(p + 1);
  if (*p == '}') return true;
  while (*p) {
    if (msg.count >= (int)(sizeof(msg.fields) / sizeof(msg.fields[0]))) return false;
    Args::Field& f = msg.fields[msg.count];
    f.kind = 0;
    f.number = 0;
    f.text[0] = 0;
    p = readString(p, f.key, sizeof(f.key));
    if (!p) return false;
    p = skipSpace(p);
    if (*p != ':') return false;
    p = skipSpace(p + 1);
    if (*p == '"') {
      p = readString(p, f.text, sizeof(f.text));
      if (!p) return false;
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
      return false;  // nested objects and arrays are not commands
    }
    msg.count++;
    p = skipSpace(p);
    if (*p == ',') {
      p = skipSpace(p + 1);
      continue;
    }
    return *p == '}';
  }
  return false;
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
  static const Mode all[] = {MODE_IN, MODE_IN_PULLUP, MODE_OUT, MODE_PWM, MODE_SERVO, MODE_ADC};
  for (unsigned i = 0; i < sizeof(all) / sizeof(all[0]); i++) {
    if (strcmp(name, modeName(all[i])) == 0) {
      *out = all[i];
      return true;
    }
  }
  return false;
}

static uint8_t capFor(Mode m) {
  switch (m) {
    case MODE_IN:
    case MODE_IN_PULLUP: return CAP_IN;
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
  out.writeP(OMNI_P(",\"pins\":["));
  bool first = true;
  for (int pin = 0; pin < MAX_PINS; pin++) {
    uint8_t caps = board_.caps(pin);
    if (!caps) continue;
    char buf[24];
    snprintf(buf, sizeof(buf), "%s{\"pin\":%d,\"caps\":[", first ? "" : ",", pin);
    out.write(buf);
    first = false;
    bool firstCap = true;
    static const struct {
      uint8_t cap;
      const char* name;
    } names[] = {{CAP_IN, "in"}, {CAP_OUT, "out"}, {CAP_PWM, "pwm"}, {CAP_SERVO, "servo"}, {CAP_ADC, "adc"}};
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
      if (!(caps & names[i].cap)) continue;
      out.write(firstCap ? "\"" : ",\"");
      out.write(names[i].name);
      out.writeP(OMNI_P("\""));
      firstCap = false;
    }
    out.writeP(OMNI_P("]}"));
  }
  out.writeP(OMNI_P("]"));
  writeId(out, id);
  out.writeP(OMNI_P("}\n"));
  out.end();
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

void Core::handleLine(const char* line, Out& out) {
  Args m;
  if (!parseArgs(line, m)) {
    error(out, -1, OMNI_P("not a JSON command"));
    return;
  }
  long id = -1;
  m.num("id", &id);
  const char* cmd = m.str("cmd");
  if (!cmd) {
    error(out, id, OMNI_P("missing cmd"));
    return;
  }

  if (named(cmd, OMNI_P("describe"))) {
    describe(out, id);
    return;
  }

  if (named(cmd, OMNI_P("ir.send")) || named(cmd, OMNI_P("ir_send"))) {
    if (!hal_.hasIr()) return error(out, id, OMNI_P("this board has no IR output"));
    const char* protocol = m.str("protocol");
    if (protocol && !named(protocol, OMNI_P("NEC"))) return error(out, id, OMNI_P("only NEC is supported"));
    long address, command;
    if (m.num("address", &address) && m.num("command", &command)) {
      if (address < 0 || address > 0xFFFF || command < 0 || command > 0xFF) return error(out, id, OMNI_P("address or command out of range"));
      hal_.sendIr(necFrame((uint16_t)address, (uint8_t)command));
    } else if (m.str("hex")) {
      char* end;
      unsigned long code = strtoul(m.str("hex"), &end, 16);
      if (*end) return error(out, id, OMNI_P("hex is not a number"));
      hal_.sendIr(necFromMsbCode((uint32_t)code));
    } else {
      return error(out, id, OMNI_P("needs address and command, or hex"));
    }
    return ack(out, id, OMNI_P("ir.send"), -1, false, 0);
  }

  long pinNum;
  bool hasPin = m.num("pin", &pinNum);
  int pin = (int)pinNum;
  uint8_t caps = hasPin ? board_.caps(pin) : 0;

  if (named(cmd, OMNI_P("pin.mode"))) {
    if (!hasPin || !caps) return error(out, id, OMNI_P("pin not available on this board"));
    Mode mode;
    const char* name = m.str("mode");
    if (!name || !modeFromName(name, &mode)) return error(out, id, OMNI_P("mode must be in, in_pullup, out, pwm, servo or adc"));
    if (!(caps & capFor(mode))) return error(out, id, OMNI_P("this pin cannot do that mode"));
    // Setting the mode a pin already has changes nothing, so the host can
    // re-send its whole pin setup at any time without switching outputs off.
    if (modes_[pin] == mode) return ack(out, id, OMNI_P("pin.mode"), pin, false, 0);
    modes_[pin] = mode;
    written_[pin] = 0;
    hal_.setMode(pin, mode);
    return ack(out, id, OMNI_P("pin.mode"), pin, false, 0);
  }

  // v1 compatibility: gpio_write sets the pin to output on first use.
  if (named(cmd, OMNI_P("gpio_write"))) {
    if (!hasPin || !(caps & CAP_OUT)) return error(out, id, OMNI_P("pin not allowed"));
    if (modes_[pin] != MODE_OUT) {
      modes_[pin] = MODE_OUT;
      hal_.setMode(pin, MODE_OUT);
    }
    cmd = "pin.write";
  }

  if (named(cmd, OMNI_P("pin.write")) || named(cmd, OMNI_P("pwm.write")) || named(cmd, OMNI_P("servo.write"))) {
    if (!hasPin || !caps) return error(out, id, OMNI_P("pin not available on this board"));
    long value;
    if (!m.num("value", &value)) return error(out, id, OMNI_P("needs value"));
    if (named(cmd, OMNI_P("pin.write"))) {
      if (modes_[pin] != MODE_OUT) return error(out, id, OMNI_P("set pin.mode out first"));
      int v = value ? 1 : 0;
      hal_.writeDigital(pin, v);
      written_[pin] = v;
      return ack(out, id, OMNI_P("pin.write"), pin, true, v);
    }
    if (named(cmd, OMNI_P("pwm.write"))) {
      if (modes_[pin] != MODE_PWM) return error(out, id, OMNI_P("set pin.mode pwm first"));
      if (value < 0 || value > 100) return error(out, id, OMNI_P("pwm value is 0 to 100"));
      hal_.writePwmPercent(pin, (int)value);
      written_[pin] = (int)value;
      return ack(out, id, OMNI_P("pwm.write"), pin, true, (int)value);
    }
    if (modes_[pin] != MODE_SERVO) return error(out, id, OMNI_P("set pin.mode servo first"));
    if (value < 0 || value > 180) return error(out, id, OMNI_P("servo value is 0 to 180"));
    hal_.writeServo(pin, (int)value);
    written_[pin] = (int)value;
    return ack(out, id, OMNI_P("servo.write"), pin, true, (int)value);
  }

  if (named(cmd, OMNI_P("pin.read"))) {
    if (!hasPin || !caps) return error(out, id, OMNI_P("pin not available on this board"));
    if (modes_[pin] == MODE_NONE) return error(out, id, OMNI_P("set pin.mode first"));
    return ack(out, id, OMNI_P("pin.read"), pin, true, readValue(pin));
  }

  if (named(cmd, OMNI_P("pin.watch"))) {
    if (!hasPin || !caps) return error(out, id, OMNI_P("pin not available on this board"));
    if (modes_[pin] != MODE_IN && modes_[pin] != MODE_IN_PULLUP && modes_[pin] != MODE_ADC) {
      return error(out, id, OMNI_P("only input pins can be watched"));
    }
    Watch* w = findWatch(pin);
    long off = 0;
    if (m.num("off", &off) && off) {
      if (w) w->pin = -1;
      return ack(out, id, OMNI_P("pin.watch"), pin, false, 0);
    }
    if (!w) w = findWatch(-1);
    if (!w) return error(out, id, OMNI_P("too many watched pins"));
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
    return ack(out, id, OMNI_P("pin.watch"), pin, true, w->last);
  }

  if (extension_ && extension_->handle(cmd, m, id, out)) return;
  error(out, id, OMNI_P("unknown command"));
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

}  // namespace omni
