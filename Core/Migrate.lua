-- Saved-data schema. ReadyToWorkDB.schema says which shape the saved table has; each step below turns one
-- schema into the next and runs once, in order, before the defaults are filled in. A fresh table starts at the
-- current schema. Steps must only reshape what they find: a value the player chose is never reset here.

local _, Helper = ...

Helper.SCHEMA = 5

local STEPS = {}

-- 1 -> 2 (ReadyToWork 1.40.0). Saved tables before 1.40 carry no schema number.
STEPS[2] = function(db)
  -- Layer Buddies' preferences, left behind when it was folded into BalHelper.
  db.layer = nil
  -- Bar undo is kept for the session only since 1.30.0: a saved undo could wipe days of bar edits.
  if type(db.bars) == "table" then
    for _, character in pairs(db.bars) do
      if type(character) == "table" and type(character.specs) == "table" then
        for _, record in pairs(character.specs) do
          if type(record) == "table" then
            record.undo, record.undoActive, record.undoBase = nil, nil, nil
          end
        end
      end
    end
  end
end

-- 2 -> 3 (ReadyToWork 1.50.0). The brown settings bag and the blue fan bag became one minimap button, in the
-- blue bag's place. The blue bag always showed, so the one button shows too; the brown bag's place is gone.
STEPS[3] = function(db)
  if type(db.minimap) == "table" then
    db.minimap.angle = nil
    db.minimap.enabled = true
  end
end

-- 3 -> 4 (ReadyToWork 1.51.0). The white items chosen for selling are kept by name, not by item link: a link
-- carries colour codes and an item string whose format can change. The window shows the link again when the
-- game has the item loaded.
STEPS[4] = function(db)
  if type(db.vendor) == "table" and type(db.vendor.included) == "table" then
    for id, label in pairs(db.vendor.included) do
      if type(label) == "string" then
        db.vendor.included[id] = label:match("|h%[(.-)%]|h") or label
      end
    end
  end
end

-- 4 -> 5 (ReadyToWork 1.55.0). Rare detection was removed; drop its leftover saved data, frame placement and hint.
STEPS[5] = function(db)
  db.rares = nil
  if type(db.positions) == "table" then
    db.positions.rares = nil
  end
  if type(db.general) == "table" and type(db.general.hints) == "table" then
    db.general.hints.rares = nil
  end
end

-- Brings `db` up to the current schema. `fresh`: a new, empty table. Returns false (and touches nothing) when
-- the table was written by a newer ReadyToWork whose shape this one can't know.
function Helper.Migrate(db, fresh)
  if fresh then
    db.schema = Helper.SCHEMA
    return true
  end
  local from = tonumber(db.schema) or 1
  if from > Helper.SCHEMA then
    Helper.savedTooNew = from
    return false
  end
  for version = from + 1, Helper.SCHEMA do
    STEPS[version](db)
    db.schema = version
  end
  return true
end
