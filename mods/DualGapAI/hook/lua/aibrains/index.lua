-- Appended to FAF's /lua/aibrains/index.lua (newer FAF builds map lobby keys to
-- brain classes there). Point our keys at the standard legacy-builder brain so
-- the AIBaseTemplates / AIBuilders system drives them. Guarded so that older
-- builds without this table are unaffected.
if keyToBrain then
    keyToBrain['dualgap'] = keyToBrain['dualgap'] or keyToBrain['adaptive'] or keyToBrain['medium']
    keyToBrain['dualgapcheat'] = keyToBrain['dualgapcheat'] or keyToBrain['adaptivecheat'] or keyToBrain['dualgap']
end
