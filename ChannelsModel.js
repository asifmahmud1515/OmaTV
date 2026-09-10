// ChannelsModel.js — Channel filtering and grouping logic for Oma TV

function parseChannels(jsonString) {
  try {
    var channels = JSON.parse(jsonString || "[]")
    if (!Array.isArray(channels)) return []
    return channels.filter(function(ch) {
      return ch && ch.url && ch.name
    })
  } catch (e) {
    return []
  }
}

function filterChannels(channels, text, group) {
  var lowerText = (text || "").toLowerCase()
  var result = []

  for (var i = 0; i < channels.length; i++) {
    var ch = channels[i]
    // Group filter
    if (group && group !== "All" && ch.group !== group) continue
    // Text filter
    if (lowerText !== "") {
      if (ch.name.toLowerCase().indexOf(lowerText) === -1 &&
          ch.group.toLowerCase().indexOf(lowerText) === -1) continue
    }
    result.push(ch)
  }

  return result
}

function extractGroups(channels) {
  var seen = {}
  var groups = []
  for (var i = 0; i < channels.length; i++) {
    var g = channels[i].group || "Ungrouped"
    if (!seen[g]) {
      seen[g] = true
      groups.push(g)
    }
  }
  groups.sort(function(a, b) { return a.localeCompare(b) })
  return groups
}
