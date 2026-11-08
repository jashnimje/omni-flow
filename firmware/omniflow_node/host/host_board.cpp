// A virtual OmniFlow board: the real protocol core with simulated pins,
// for tests that need a board without hardware.
//
//   host_board [--node NAME] [--pty] [--udp PORT] [--hello-to PORT] [--hello-every MS]
//
// Serial: commands on stdin, replies and events on stdout. With --pty it opens
// a pseudo-terminal instead and prints the path to open, so the engine talks
// to it exactly as to a USB board; it exits when stdin closes. UDP: listens on
// 127.0.0.1:PORT like a board on Wi-Fi, replies to the sender, and sends
// events to whoever last sent describe. Hello goes to 127.0.0.1:hello-to.
//
// Extra test commands: {"cmd":"sim.set","pin":3,"value":1} sets an input, and
// every IR frame is reported as {"event":"sim.ir","bits":"0x..."}.
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <termios.h>
#include <unistd.h>

#include "../omni_core.h"

using namespace omni;

static int simValue[MAX_PINS];
static Out* irOut = 0;
static const char* nodeName = "host_board";

class SimHal : public Hal {
 public:
  void setMode(int, Mode) override {}
  void writeDigital(int, int) override {}
  int readDigital(int pin) override { return simValue[pin] ? 1 : 0; }
  int readAnalogPercent(int pin) override { return simValue[pin]; }
  void writePwmPercent(int, int) override {}
  void writeServo(int, int) override {}
  bool hasIr() override { return true; }
  void sendIr(uint32_t bits) override {
    if (!irOut) return;
    char buf[96];
    snprintf(buf, sizeof(buf), "{\"node\":\"%s\",\"event\":\"sim.ir\",\"bits\":\"0x%08x\"}\n", nodeName, bits);
    irOut->write(buf);
    irOut->end();
  }
  unsigned long millis() override {
    struct timeval tv;
    gettimeofday(&tv, 0);
    return (unsigned long)(tv.tv_sec * 1000UL + tv.tv_usec / 1000);
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
  void end() override {
    if (set && fd >= 0 && len) sendto(fd, buf, len, 0, (sockaddr*)&to, sizeof(to));
    len = 0;
  }
};

// Sends every line to both serial and the last UDP peer, like the firmware.
class BothOut : public Out {
 public:
  Out& a;
  Out& b;
  BothOut(Out& x, Out& y) : a(x), b(y) {}
  void write(const char* text) override {
    a.write(text);
    b.write(text);
  }
  void end() override {
    a.end();
    b.end();
  }
};

// The setup commands the real sketch handles, simulated: Wi-Fi joins at
// once and reports the loopback address.
static char simNode[24];
static char simSsid[33];
static Core* simCore = 0;
static int simUdpPort = 0;

class SimSetup : public Extension {
 public:
  bool handle(const char* cmd, const Args& args, long id, Out& out) override {
    char buf[200];
    if (!strcmp(cmd, "wifi.set")) {
      const char* ssid = args.str("ssid");
      if (!ssid || !ssid[0]) {
        simCore->error(out, id, "ssid is 1 to 32 characters");
        return true;
      }
      snprintf(simSsid, sizeof(simSsid), "%s", ssid);
      simCore->ack(out, id, "wifi.set", -1, false, 0);
      return true;
    }
    if (!strcmp(cmd, "wifi.status")) {
      if (simSsid[0]) {
        snprintf(buf, sizeof(buf),
                 "{\"node\":\"%s\",\"event\":\"wifi\",\"configured\":true,\"connected\":true,"
                 "\"ip\":\"127.0.0.1\",\"port\":%d,\"rssi\":-50,\"id\":%ld}\n",
                 simCore->node(), simUdpPort, id);
      } else {
        snprintf(buf, sizeof(buf),
                 "{\"node\":\"%s\",\"event\":\"wifi\",\"configured\":false,\"connected\":false,\"id\":%ld}\n",
                 simCore->node(), id);
      }
      out.write(buf);
      out.end();
      return true;
    }
    if (!strcmp(cmd, "node.set")) {
      const char* name = args.str("name");
      if (!name || !name[0] || strlen(name) >= sizeof(simNode)) {
        simCore->error(out, id, "name is 1 to 23 characters");
        return true;
      }
      snprintf(simNode, sizeof(simNode), "%s", name);
      simCore->setNode(simNode);
      nodeName = simNode;
      simCore->ack(out, id, "node.set", -1, false, 0);
      return true;
    }
    if (!strcmp(cmd, "ir.pin")) {
      simCore->ack(out, id, "ir.pin", -1, false, 0);
      return true;
    }
    return false;
  }
};

static bool simCommand(const char* line, Out& out) {
  if (!strstr(line, "\"sim.set\"")) return false;
  const char* p = strstr(line, "\"pin\"");
  const char* v = strstr(line, "\"value\"");
  if (p && v) {
    int pin = atoi(strchr(p, ':') + 1);
    int value = atoi(strchr(v, ':') + 1);
    if (pin >= 0 && pin < MAX_PINS) simValue[pin] = value;
  }
  const char* id = strstr(line, "\"id\"");
  char buf[96];
  if (id) {
    snprintf(buf, sizeof(buf), "{\"node\":\"%s\",\"event\":\"sim.ack\",\"id\":%ld}\n", nodeName, atol(strchr(id, ':') + 1));
  } else {
    snprintf(buf, sizeof(buf), "{\"node\":\"%s\",\"event\":\"sim.ack\"}\n", nodeName);
  }
  out.write(buf);
  out.end();
  return true;
}

int main(int argc, char** argv) {
  int udpPort = 0, helloTo = 0, helloEvery = 30000;
  bool usePty = false;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--pty")) {
      usePty = true;
      continue;
    }
    if (i + 1 >= argc) break;
    if (!strcmp(argv[i], "--node")) nodeName = argv[i + 1];
    if (!strcmp(argv[i], "--udp")) udpPort = atoi(argv[i + 1]);
    if (!strcmp(argv[i], "--hello-to")) helloTo = atoi(argv[i + 1]);
    if (!strcmp(argv[i], "--hello-every")) helloEvery = atoi(argv[i + 1]);
    i++;
  }
  SimHal hal;
  Core core(nodeName, "omniflow-node/2 host", BOARD_HOST, hal);
  SimSetup setup;
  simCore = &core;
  simUdpPort = udpPort;
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
  BothOut both(serial, udp);
  irOut = &both;

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
  unsigned long lastHello = 0;
  bool firstHello = true;
  char line[1024];
  size_t lineLen = 0;
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
          if (lineLen && !simCommand(line, serial)) core.handleLine(line, serial);
          lineLen = 0;
        } else if (c != '\r' && lineLen < sizeof(line) - 1) {
          line[lineLen++] = c;
        }
      }
    }
    if (udp.fd >= 0 && n > 0 && (fds[1].revents & POLLIN)) {
      char buf[1024];
      sockaddr_in from{};
      socklen_t fromLen = sizeof(from);
      ssize_t got = recvfrom(udp.fd, buf, sizeof(buf) - 1, 0, (sockaddr*)&from, &fromLen);
      if (got > 0) {
        buf[got] = 0;
        UdpOut reply;
        reply.fd = udp.fd;
        reply.to = from;
        reply.set = true;
        if (strstr(buf, "\"describe\"")) {
          udp.to = from;
          udp.set = true;
        }
        if (!simCommand(buf, reply)) core.handleLine(buf, reply);
      }
    }
    unsigned long now = hal.millis();
    if (hello.set && (firstHello || now - lastHello >= (unsigned long)helloEvery)) {
      core.hello(hello, udpPort);
      lastHello = now;
      firstHello = false;
    }
    core.poll(both);
  }
}
