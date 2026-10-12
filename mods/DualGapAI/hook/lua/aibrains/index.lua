-- Appended to FAF's /lua/aibrains/index.lua (newer FAF builds map lobby keys to
-- brain classes there). Point our keys (every difficulty level, plain and
-- cheating) at the standard legacy-builder brain so the AIBaseTemplates /
-- AIBuilders system drives them. Guarded so that older builds without this
-- table are unaffected.
if keyToBrain then
    local plain = keyToBrain['dualgap'] or keyToBrain['adaptive'] or keyToBrain['medium']
    local cheat = keyToBrain['dualgapcheat'] or keyToBrain['adaptivecheat'] or plain
    for _, level in ipairs({ '', 'easy', 'normal', 'hard' }) do
        keyToBrain['dualgap' .. level] = keyToBrain['dualgap' .. level] or plain
        keyToBrain['dualgap' .. level .. 'cheat'] = keyToBrain['dualgap' .. level .. 'cheat'] or cheat
    end
end
