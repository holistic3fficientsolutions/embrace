# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "../lib/crymble-ui/src/csfml3/wrapper"

module Constant
    # Embedded font: Cousine-Regular.ttf (Google Font, Apache 2.0, has Greek glyphs)
    FontRaw = {{ read_file("#{__DIR__}/../resources/Cousine-Regular.ttf") }}.to_slice
    IconSize = 64
    Rank = "Rank"
    ShowAll = "(Show all records?)"
    Unnamed = "(unnamed)"
    NoReference = "(no reference)"
    # single source of truth: read the version from shard.yml at compile time
    Version = {{ read_file("#{__DIR__}/../shard.yml").lines.find { |l| l.starts_with?("version:") }.split(":")[1].strip }}
    BuildVersion = {{`git rev-parse HEAD`.stringify}}.strip + ({{`git status --porcelain`.stringify}} == "" ? "" : "*")
    BuildDate = Time.parse({{`git log -1 --format=%cd --date=iso`.stringify}}.strip, "%F", Time::Location::UTC) # git yields e.g.: 2025-06-24 20:40:22 +0200
    BuildMode = {{ flag?(:release) ? "release mode" : "normal mode" }}
end
