#!/usr/bin/env bash

FILE="lib/frame-filter.ts"

echo "Creating backup..."
cp "$FILE" "$FILE.bak"

echo "Fixing no_motion block..."
perl -0777 -i -pe '
s/if \(motionLevel < this\.cfg\.motionThreshold\) \{
\s*return this\.result\(false, 0, '\''no_motion'\'', \{/if (motionLevel < this.cfg.motionThreshold) {\n      this.lastImageData = frame\n\n      return this.result(false, 0, '\''no_motion'\'', {/s
' "$FILE"

echo "Fixing low_score block..."
perl -0777 -i -pe '
s/if \(score < this\.cfg\.anomalyThreshold\) \{
\s*return this\.result\(false, score, '\''low_score'\'', debug\)/if (score < this.cfg.anomalyThreshold) {\n      this.lastImageData = frame\n\n      return this.result(false, score, '\''low_score'\'', debug)/s
' "$FILE"

echo "Fixing cooldown block..."
perl -0777 -i -pe '
s/if \(Date\.now\(\) - this\.lastGptCall < this\.cfg\.cooldownMs\) \{
\s*return this\.result\(false, score, '\''cooldown'\'', debug\)/if (Date.now() - this.lastGptCall < this.cfg.cooldownMs) {\n      this.lastImageData = frame\n\n      return this.result(false, score, '\''cooldown'\'', debug)/s
' "$FILE"

echo "Done."
echo "Backup saved as $FILE.bak"
