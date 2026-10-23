#include "anitorrent_c.h"
#include <libtorrent/bencode.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/torrent_info.hpp>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <thread>
#include <vector>

namespace fs = std::filesystem;
namespace lt = libtorrent;
using namespace std::chrono_literals;

static void require(bool value, const std::string &message) {
    if (!value) throw std::runtime_error(message + ": " + ani_last_error());
}
struct events {
    bool metadata = false;
    bool complete = false;
    bool resumed = false;
    std::string resume_path;
};
static void on_event(void *context, int kind, uint32_t, int, const void *payload) {
    auto &result = *static_cast<events *>(context);
    if (kind == ANI_METADATA || kind == ANI_CHECKED) result.metadata = true;
    if (kind == ANI_FILE_COMPLETED) result.complete = true;
    if (kind == ANI_RESUME) {
        auto copy = ani_resume_copy(payload);
        if (copy) {
            result.resumed = ani_resume_save(copy, result.resume_path.c_str()) == 0;
            ani_resume_destroy(copy);
        }
    }
}
template<typename Predicate>
static void poll_until(ani_session *session, events &result, Predicate done) {
    auto deadline = std::chrono::steady_clock::now() + 60s;
    while (!done()) {
        require(std::chrono::steady_clock::now() < deadline, "Timed out waiting for torrent event");
        require(ani_session_poll(session, on_event, &result) == 0, "Poll");
        std::this_thread::sleep_for(20ms);
    }
}
static std::vector<char> read_file(const fs::path &path) {
    std::ifstream stream(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
}

int main() {
    const auto root = fs::temp_directory_path() / ("animeko-native-transfer-" +
        std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    try {
        fs::create_directories(root / "seed");
        fs::create_directories(root / "download");
        std::vector<char> original(256 * 1024);
        for (size_t i = 0; i < original.size(); ++i) original[i] = static_cast<char>((i * 31 + i / 17) & 255);
        {
            std::ofstream out(root / "seed" / "episode.mp4", std::ios::binary);
            out.write(original.data(), original.size());
        }
        lt::file_storage files;
        files.add_file("episode.mp4", original.size());
        lt::create_torrent creator(files, 16 * 1024, lt::create_torrent::v1_only);
        lt::set_piece_hashes(creator, (root / "seed").string());
        std::vector<char> encoded;
        lt::bencode(std::back_inserter(encoded), creator.generate());
        auto info = std::make_shared<lt::torrent_info>(encoded.data(), encoded.size());

        lt::settings_pack config;
        config.set_str(lt::settings_pack::listen_interfaces, "127.0.0.1:0");
        config.set_bool(lt::settings_pack::enable_dht, false);
        config.set_bool(lt::settings_pack::enable_lsd, false);
        config.set_bool(lt::settings_pack::enable_upnp, false);
        config.set_bool(lt::settings_pack::enable_natpmp, false);
        lt::session seed(config);
        lt::add_torrent_params parameters;
        parameters.ti = info;
        parameters.save_path = (root / "seed").string();
        parameters.flags |= lt::torrent_flags::seed_mode;
        parameters.flags &= ~lt::torrent_flags::auto_managed;
        parameters.flags &= ~lt::torrent_flags::paused;
        auto seed_handle = seed.add_torrent(parameters);
        for (int i = 0; i < 200 && seed.listen_port() == 0; ++i) std::this_thread::sleep_for(20ms);
        require(seed.listen_port() != 0, "Seeder port");
        const auto magnet = lt::make_magnet_uri(seed_handle) + "&x.pe=127.0.0.1:" + std::to_string(seed.listen_port());

        ani_settings settings{"AnimekoTransferTest/1", "-AT0001-", "test", 0, 0, 200};
        using session_ptr = std::unique_ptr<ani_session, decltype(&ani_session_destroy)>;
        using handle_ptr = std::unique_ptr<ani_handle, decltype(&ani_handle_destroy)>;
        session_ptr client(ani_session_create(&settings, nullptr, nullptr), ani_session_destroy);
        require(bool(client), "Create downloader");
        handle_ptr handle(ani_session_add(client.get(), magnet.c_str(), nullptr, nullptr,
            (root / "download").string().c_str()), ani_handle_destroy);
        require(bool(handle), "Add magnet");
        events result;
        result.resume_path = (root / "download" / "fastresume").string();
        require(ani_session_resume(client.get()) == 0, "Resume session");
        poll_until(client.get(), result, [&] { return result.metadata; });
        auto metadata = ani_handle_info(handle.get());
        require(metadata != nullptr, "Magnet metadata");
        require(ani_info_file_count(metadata) == 1, "File count");
        require(ani_info_file_size(metadata, 0) == static_cast<int64_t>(original.size()), "File size");
        ani_info_destroy(metadata);
        require(!result.complete, "Unselected files must not download");
        require(ani_handle_priority(handle.get(), 0, 7) == 0, "Select file");
        require(ani_handle_resume(handle.get()) == 0, "Resume handle");
        poll_until(client.get(), result, [&] { return result.complete; });
        require(read_file(root / "download" / "episode.mp4") == original, "Transferred bytes differ");
        result.resumed = false;
        require(ani_handle_post_resume(handle.get()) == 0, "Request resume data");
        poll_until(client.get(), result, [&] { return result.resumed; });
        require(fs::file_size(result.resume_path) > 0, "Resume file is empty");
        require(ani_session_remove(client.get(), handle.get()) == 0, "Remove torrent");
        handle.reset();
        client.reset();

        client.reset(ani_session_create(&settings, nullptr, nullptr));
        require(bool(client), "Recreate downloader");
        handle.reset(ani_session_add(client.get(), magnet.c_str(), nullptr,
            result.resume_path.c_str(), (root / "download").string().c_str()));
        require(bool(handle), "Restore torrent");
        require(ani_handle_valid(handle.get()) == 1, "Restored handle");
        require(read_file(root / "download" / "episode.mp4") == original, "Restart changed downloaded bytes");
        ani_session_remove(client.get(), handle.get());
        handle.reset();
        client.reset();
        seed.remove_torrent(seed_handle);
        std::cout << "PASS: magnet metadata, selective download, byte verification, resume persistence, restart\n";
        fs::remove_all(root);
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        fs::remove_all(root);
        return 1;
    }
}
