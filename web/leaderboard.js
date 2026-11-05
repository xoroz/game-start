// Bridge between the game (Lua in love.js) and the leaderboard API.
// Lua cannot make HTTP requests, so it prints a request line:
//   STARDRIFT_API|<save dir>|top
//   STARDRIFT_API|<save dir>|submit|ABC|1234|5
// and this script answers by writing <save dir>/leaderboard.txt, which the game polls:
//   ok <rank or 0>
//   ABC 1234 5        (up to 5 lines, best first)
// or "err <reason>" when the server cannot be reached.
// build.sh injects this file into the love.js index.html before game.js.
(function () {
  var API = "api/scores";  // relative, so it works wherever the game folder is hosted
  var PREFIX = "STARDRIFT_API|";
  var print = Module.print || console.log.bind(console);

  function reply(dir, text) {
    var path = dir.replace(/\/+$/, "");
    try { Module.FS_unlink(path + "/leaderboard.txt"); } catch (e) {}
    Module.FS_createPath("/", path.replace(/^\/+/, ""), true, true);
    Module.FS_createDataFile(path, "leaderboard.txt", text, true, true);
  }

  function format(data) {
    var lines = ["ok " + (data.rank || 0)];
    (data.top || []).forEach(function (e) {
      lines.push(e.name + " " + e.score + " " + e.level);
    });
    return lines.join("\n") + "\n";
  }

  function handle(parts) {
    var dir = parts[1], op = parts[2], req;
    if (op === "submit") {
      req = fetch(API, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: parts[3], score: Number(parts[4]), level: Number(parts[5]) }),
      });
    } else {
      req = fetch(API, { cache: "no-store" });
    }
    req.then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    }).then(function (data) {
      reply(dir, format(data));
    }).catch(function (e) {
      console.warn("leaderboard:", e);
      reply(dir, "err " + e.message + "\n");
    });
  }

  Module.print = function (line) {
    if (typeof line === "string" && line.indexOf(PREFIX) === 0) {
      handle(line.split("|"));
    } else {
      print(line);
    }
  };
})();
