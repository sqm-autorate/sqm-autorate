# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [0.1.2] - 2021-12-20

### Fixed

- Fixed LUA_PATH in the README.md doc.

## [0.1.1] - 2021-12-19

### Added

- Add this CHANGELOG.md file with relevant history.

### Changed

- Updated README.md to include Lua specifics.
- Updated `sqm-autorate` service file for the Lua script.

### Removed

- Removed sqm-autorotate.sh and ts-request-poc.py from this `port-from-shell` branch.

## [0.1.0] - 2021-12-16

### Added

- Formal "public" release for testing to validate behavior against the shell OWD version.

## [0.0.19] - 2021-12-16

### Changed

- More tuning to match shell version behavior.

### Fixed

- Fixed issues causing discrepencies from shell script. The discrepencies were caused by translation of the awk syntax from shell to Lua.

## [0.0.18] - 2021-12-15

### Added

- Added boolean `enable_verbose_baseline_output` to toggle more verbose baseline outputs.
- Added file-level comments with brief description and attributions.

### Changed

- Began tidying up the code and preparing for a more "formal" public test release.
- Cleaned up imports to match current Lua standard.
- Further cleanup of variable naming per this standard: [https://github.com/luarocks/lua-style-guide](https://github.com/luarocks/lua-style-guide)

## [0.0.17] - 2021-12-14

### Fixed

- Found the porting error in rate control logic. TC adjustments are now occuring.

## [0.0.16] - 2021-12-13

### Added

- Ported `update_rates()` and `get_next_shaper_rate()` from the shell version.
- Added TC manipulation commands to match shell version.

## [0.0.15] - 2021-12-13

### Added

- Created `logger(loglevel, message)` function to help standardize output style.

## [0.0.14] - 2021-12-13

### Changed

- Updated `get_time_after_midnight_ms()` to use new `get_current_time()` function.

## [0.0.13] - 2021-12-13

### Added

- Added `get_current_time()` function that accounts for differences in `time.clock_gettime` (`posix.time`) between Lua 5.1 and Lua 5.2+.

### Changed

- Updated `pinger()` to use the new `get_current_time()` function.

## [0.0.12] - 2021-12-12

### Added

- Timeout of 500μs for receive and send socket settings.

## [0.0.11] - 2021-12-12

### Changed

- Complete refactor to a Lua producer-consumer coroutine model.

## [0.0.10] - 2021-12-11

### Added

- Added a proper WHILE loop within the receive function.

## [0.0.9] - 2021-12-11

### Added

- Troubleshooting aids to resolve some bugs.

### Fixed

- Formatting and variable naming convention.

## [0.0.8] - 2021-12-11

### Added

- Added dynamic packet ID generation.

## [0.0.7] - 2021-12-11

### Changed

- Refactored to separate transmit function from receive function.
- Added separate coroutines for transmit and send.

## [0.0.6] - 2021-12-11

### Added

- Improvements to validate the receive code only checks for replies to packets we transmitted.

## [0.0.5] - 2021-12-11

### Added

- Bail out for cases where socket.SOCK_RAW privilige could not be acquired.

### Changed

- Improvements and cleanup around the send/receive ICMP TS function.

## [0.0.4] - 2021-12-10

### Changed

- Refactored from a sequential WHILE loop to a series of Lua coroutines.

## [0.0.3] - 2021-12-10

### Added

- Initial built-out of OWD constructs.

## [0.0.2] - 2021-12-09

### Added

- Added looping with an array of reflector IPs.

## [0.0.1] - 2021-12-09

### Added

- Completed initial PoC for Lua based sending of ICMP TS packets.

## [0.0.0] - Template

### Added

- N/A

### Changed

- N/A

### Fixed

- N/A

### Removed

- N/A