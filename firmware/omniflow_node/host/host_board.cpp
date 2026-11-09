// A virtual OmniFlow board: the real protocol core and setup commands with
// simulated pins, for tests that need a board without hardware.
//
//   host_board [--node NAME] [--pty] [--udp PORT] [--hello-to PORT] [--hello-every MS]
//
// Serial: commands on stdin, replies and events on stdout. With --pty it opens
// a pseudo-terminal instead and prints the path to open, so the engine talks
// to it exactly as to a USB board; it exits when stdin closes. UDP: listens on
// 127.0.0.1:PORT like a board on Wi-Fi, replies to the sender, and sends
// events to the last three hosts that sent describe in the past 90 s. Hello
// goes to 127.0.0.1:hello-to.
//
// Extra test commands: {"cmd":"sim.set","pin":3,"value":1} sets an input, and
// {"cmd":"sim.wifi","connected":false} drops the simulated Wi-Fi link (true
// brings it back, which sends a hello at once, as a board does on a rejoin).
// Every IR frame is reported as {"event":"sim.ir","bits":"0x..."}, and every
// RF send as {"event":"sim.rf","protocol":1,"code":5393,"bits":24,"repeat":10}.
// {"cmd":"sim.nfc","uid":"04a1b2c3d4e5f6","ms":500} holds a tag on the NFC
// reader set with periph.set (either type) for ms milliseconds, or for one
// read without ms. The core reads it like a real tag, so the board reports
// {"event":"nfc.scanned","uid":"04a1b2c3d4e5f6"} once per presentation.
// Wi-Fi joins at once and reports the loopback address, and wifi.status adds
// "passwordLength" so a test can see the password arrived. A node.set that
// changes the name sends a hello under the new name at once.
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "../omni_core.h"

using namespace omni;

static int simValue[MAX_PINS];
static Out* irOut = 0;
static Core* simCore = 0;
static bool simWifiUp = true;
static Link* simLink = 0;
// The simulated tag on the reader: its UID, and until when it stays.
static uint8_t simUid[NFC_UID_MAX];
static int simUidLen = 0;
static bool simUidOnce = false;
static unsigned long simUidUntil = 0;
static uint8_t simReader = PERIPH_NONE;

static unsigned long monotonicMs() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (unsigned long)ts.tv_sec * 1000UL + (unsigned long)(ts.tv_nsec / 1000000);
}

class SimHal : public Hal {
 public:
  // Counts from start like a board's millis(), so it wraps the same way.
  unsigned long start = monotonicMs();
  bool setMode(int, Mode, int) override { return true; }
  void writeDigital(int, int) override {}
  int readDigital(int pin) override { return simValue[pin] ? 1 : 0; }
  int readAnalogPercent(int pin) override { return simValue[pin]; }
  void writePwmPercent(int, int) override {}
  void writeServo(int, int) override {}
  bool hasIr() override { return true; }
  void sendIr(uint32_t bits) override {
    if (!irOut) return;
    char buf[96];
    snprintf(buf, sizeof(buf), "{\"node\":\"%s\",\"event\":\"sim.ir\",\"bits\":\"0x%08x\"}\n", simCore->node(), bits);
    irOut->write(buf);
    irOut->end();
  }
  bool hasRf() override { return true; }
  void sendRf(const RfProtocol& protocol, uint32_t code, uint8_t bits, uint8_t repeat) override {
    if (!irOut) return;
    char buf[128];
    snprintf(buf, sizeof(buf), "{\"node\":\"%s\",\"event\":\"sim.rf\",\"protocol\":%u,\"code\":%lu,\"bits\":%u,\"repeat\":%u}\n",
             simCore->node(), protocol.number, (unsigned long)code, bits, repeat);
    irOut->write(buf);
    irOut->end();
  }
  void startNfc(uint8_t type, int, int) override {
    simReader = type;
    simUidLen = 0;
  }
  int pollNfc(uint8_t* uid) override {
    if (!simUidLen) return 0;
    if (!simUidOnce && (long)(millis() - simUidUntil) >= 0) {
      simUidLen = 0;
      return 0;
    }
    simUidOnce = false;
    memcpy(uid, simUid, (size_t)simUidLen);
    return simUidLen;
  }
  unsigned long millis() override { return monotonicMs() - start; }
};

static int hexDigit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// Reads hex, with any ':' between bytes ignored. Returns the byte count, or
// 0 unless it is a type A UID length (4, 7 or 10).
static int parseUid(const char* text, uint8_t* uid) {
  int n = 0;
  for (const char* p = text; *p;) {
    if (*p == ':') {
      p++;
      continue;
    }
    int hi = hexDigit(p[0]);
    int lo = hi < 0 ? -1 : hexDigit(p[1]);
    if (lo < 0 || n == NFC_UID_MAX) return 0;
    uid[n++] = (uint8_t)(hi * 16 + lo);
    p += 2;
  }
  return n == 4 || n == 7 || n == 10 ? n : 0;
}

static Settings settings;

class SimSetupHal : public SetupHal {
 public:
  void saveSettings() override {}
  void startWifi() override {}
  void stopWifi() override {}
  bool wifiConnected() override { return settings.ssid[0] != 0; }
  void localIp(uint8_t ip[4]) override {
    ip[0] = 127;
    ip[1] = 0;
    ip[2] = 0;
    ip[3] = 1;
  }
  int rssi() override { return -50; }
  void nodeRenamed() override {
    if (simLink) simLink->renamed();
  }
  void statusExtra(Out& out) override {
    char buf[32];
    snprintf(buf, sizeof(buf), ",\"passwordLength\":%d", (int)strlen(settings.password));
    out.write(buf);
  }
};

class FdOut : public Out {
 public:
  int fd = STDOUT_FILENO;
  void write(const char* text) override {
    size_t n = strlen(text);
    while (n) {
      ssize_t w = ::write(fd, text, n);
      if (w <= 0) return;
      text += w;
      n -= (size_t)w;
    }
  }
};

// Opens a pseudo-terminal in raw mode and returns the master side. The slave
// stays open here too, so the master never reads EOF between test clients.
static int openPty() {
  int master = posix_openpt(O_RDWR | O_NOCTTY);
  if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0) return -1;
  const char* name = ptsname(master);
  int slave = open(name, O_RDWR | O_NOCTTY);
  if (slave < 0) return -1;
  struct termios t;
  tcgetattr(slave, &t);
  cfmakeraw(&t);
  tcsetattr(slave, TCSANOW, &t);
  printf("%s\n", name);
  fflush(stdout);
  return master;
}

// Collects one line, then sends it as one datagram.
class UdpOut : public Out {
 public:
  int fd = -1;
  sockaddr_in to{};
  bool set = false;
  char buf[2048];
  size_t len = 0;
  void write(const char* text) override {
    size_t n = strlen(text);
    if (len + n < sizeof(buf)) {
      memcpy(buf + len, text, n);
      len += n;
    }
  }
  void sendTo(const sockaddr_in& addr) {
    if (fd >= 0 && len) sendto(fd, buf, len, 0, (const sockaddr*)&addr, sizeof(addr));
  }
  void end() override {
    if (set) sendTo(to);
    len = 0;
  }
};

// The hosts that get events, like the firmware's peer table.
static const int MAX_PEERS = 3;
static const unsigned long PEER_TTL_MS = 90000;

struct Peer {
  sockaddr_in addr;
  unsigned long seen;
  bool used;
};

static Peer peers[MAX_PEERS];

static void addPeer(const sockaddr_in& from, unsigned long now) {
  Peer* slot = 0;
  for (int i = 0; i < MAX_PEERS; i++) {
    Peer& p = peers[i];
    bool same = p.used && p.addr.sin_addr.s_addr == from.sin_addr.s_addr && p.addr.sin_port == from.sin_port;
    if (same) {
      slot = &p;
      break;
    }
    if (!slot || !p.used || (slot->used && p.seen < slot->seen)) slot = &p;
  }
  slot->addr = from;
  slot->seen = now;
  slot->used = true;
}

// Sends every line to serial and to every live peer.
class EventOut : public Out {
 public:
  EventOut(Out& serial, UdpOut& udp, Hal& hal) : serial_(serial), udp_(udp), hal_(hal) {}
  void write(const char* text) override {
    serial_.write(text);
    udp_.write(text);
  }
  void end() override {
    serial_.end();
    unsigned long now = hal_.millis();
    for (int i = 0; i < MAX_PEERS; i++) {
      if (!peers[i].used) continue;
      if (now - peers[i].seen > PEER_TTL_MS) {
        peers[i].used = false;
        continue;
      }
      udp_.sendTo(peers[i].addr);
    }
    udp_.len = 0;
  }

 private:
  Out& serial_;
  UdpOut& udp_;
  Hal& hal_;
};

static void simAck(Out& out, long id) {
  char buf[96];
  if (id >= 0) {
    snprintf(buf, sizeof(buf), "{\"node\":\"%s\",\"event\":\"sim.ack\",\"id\":%ld}\n", simCore->node(), id);
  } else {
    snprintf(buf, sizeof(buf), "{\"node\":\"%s\",\"event\":\"sim.ack\"}\n", simCore->node());
  }
  out.write(buf);
  out.end();
}

static bool simNfc(const char* line, Out& out, unsigned long now) {
  Args args;
  if (parseArgs(line, args)) return false;
  const char* cmd = args.str("cmd");
  if (!cmd || strcmp(cmd, "sim.nfc") != 0) return false;
  long id = -1, ms = 0;
  args.num("id", &id);
  args.num("ms", &ms);
  uint8_t uid[NFC_UID_MAX];
  const char* text = args.str("uid");
  int n = text ? parseUid(text, uid) : 0;
  if (simReader == PERIPH_NONE) {
    simCore->error(out, id, "no NFC reader is set, send periph.set first");
  } else if (!n) {
    simCore->error(out, id, "uid is 4, 7 or 10 bytes of hex");
  } else if (ms < 0 || ms > 600000) {
    simCore->error(out, id, "ms is 0 to 600000");
  } else {
    memcpy(simUid, uid, (size_t)n);
    simUidLen = n;
    simUidOnce = true;
    simUidUntil = now + (unsigned long)ms;
    simAck(out, id);
  }
  return true;
}

static bool simCommand(const char* line, Out& out, unsigned long now) {
  if (strstr(line, "\"sim.nfc\"")) return simNfc(line, out, now);
  bool wifi = strstr(line, "\"sim.wifi\"") != 0;
  if (!wifi && !strstr(line, "\"sim.set\"")) return false;
  const char* p = strstr(line, "\"pin\"");
  const char* v = strstr(line, "\"value\"");
  const char* pc = p ? strchr(p, ':') : 0;
  const char* vc = v ? strchr(v, ':') : 0;
  if (wifi) {
    Args args;
    long connected = 1;
    if (!parseArgs(line, args)) args.num("connected", &connected);
    simWifiUp = connected != 0;
  } else if (pc && vc) {
    int pin = atoi(pc + 1);
    int value = atoi(vc + 1);
    if (pin >= 0 && pin < MAX_PINS) simValue[pin] = value;
  }
  const char* id = strstr(line, "\"id\"");
  const char* ic = id ? strchr(id, ':') : 0;
  simAck(out, ic ? atol(ic + 1) : -1);
  return true;
}

int main(int argc, char** argv) {
  int udpPort = 0, helloTo = 0, helloEvery = 30000;
  bool usePty = false;
  const char* node = "host_board";
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--pty")) {
      usePty = true;
      continue;
    }
    if (i + 1 >= argc) break;
    if (!strcmp(argv[i], "--node")) node = argv[i + 1];
    if (!strcmp(argv[i], "--udp")) udpPort = atoi(argv[i + 1]);
    if (!strcmp(argv[i], "--hello-to")) helloTo = atoi(argv[i + 1]);
    if (!strcmp(argv[i], "--hello-every")) helloEvery = atoi(argv[i + 1]);
    i++;
  }
  settings.periph.irPin = -1;
  settings.periph.rfPin = -1;
  snprintf(settings.node, sizeof(settings.node), "%s", node);
  SimHal hal;
  Core core(settings.node, "omniflow-node/2 host", BOARD_HOST, hal);
  SimSetupHal setupHal;
  Setup setup(core, settings, setupHal, udpPort);
  simCore = &core;
  core.setExtension(&setup);
  FdOut serial;
  int serialIn = STDIN_FILENO;
  if (usePty) {
    serialIn = openPty();
    if (serialIn < 0) {
      perror("pty");
      return 1;
    }
    serial.fd = serialIn;
  }
  UdpOut udp;
  EventOut events(serial, udp, hal);
  irOut = &events;

  if (udpPort) {
    udp.fd = socket(AF_INET, SOCK_DGRAM, 0);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(udpPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(udp.fd, (sockaddr*)&addr, sizeof(addr)) != 0) {
      perror("bind");
      return 1;
    }
  }
  UdpOut hello;
  if (helloTo && udp.fd >= 0) {
    hello.fd = udp.fd;
    hello.to.sin_family = AF_INET;
    hello.to.sin_port = htons(helloTo);
    hello.to.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    hello.set = true;
  }

  core.boot(serial);
  Link link((unsigned long)helloEvery);
  simLink = &link;
  // The same line limit as the firmware on a Wi-Fi board.
  char line[200];
  size_t lineLen = 0;
  bool lineTooLong = false;
  while (true) {
    pollfd fds[3] = {{serialIn, POLLIN, 0}, {udp.fd, POLLIN, 0}, {usePty ? STDIN_FILENO : -1, POLLIN, 0}};
    int n = poll(fds, 3, 10);
    if (n > 0 && (fds[2].revents & (POLLIN | POLLHUP))) {
      char c;
      if (read(STDIN_FILENO, &c, 1) <= 0) return 0;  // the test closed stdin
    }
    if (n > 0 && (fds[0].revents & (POLLIN | POLLHUP))) {
      char chunk[256];
      ssize_t got = read(serialIn, chunk, sizeof(chunk));
      if (got <= 0 && !usePty) return 0;  // stdin closed: the test is done
      for (ssize_t k = 0; k < got; k++) {
        char c = chunk[k];
        if (c == '\n') {
          line[lineLen] = 0;
          if (lineTooLong) {
            core.error(serial, -1, "line too long");
          } else if (lineLen && !simCommand(line, serial, hal.millis())) {
            setup.fromSerial = true;
            core.handleLine(line, serial);
            setup.fromSerial = false;
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
    if (udp.fd >= 0 && n > 0 && (fds[1].revents & POLLIN)) {
      char buf[sizeof(line)];
      sockaddr_in from{};
      socklen_t fromLen = sizeof(from);
      ssize_t got = recvfrom(udp.fd, buf, sizeof(buf) - 1, 0, (sockaddr*)&from, &fromLen);
      if (got > 0) {
        buf[got] = 0;
        UdpOut reply;
        reply.fd = udp.fd;
        reply.to = from;
        reply.set = true;
        if (!simCommand(buf, reply, hal.millis()) && core.handleLine(buf, reply)) addPeer(from, hal.millis());
      }
    }
    // The first update is the join, which says hello at once.
    if ((link.update(simWifiUp, hal.millis()) & Link::HELLO) && hello.set) core.hello(hello, udpPort);
    core.poll(events);
  }
}
