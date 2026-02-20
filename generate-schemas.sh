#!/bin/bash
set -e

echo "🔧 Generating values schemas for all charts..."

# Check if helm-schema-gen plugin is installed
if ! helm plugin list | grep -q schema-gen; then
    echo "📦 Installing helm-schema-gen plugin..."
    helm plugin install https://github.com/karuppiah7890/helm-schema-gen.git
fi

# Generate schema for each chart
for chart in charts/*/; do
    chart_name=$(basename "$chart")
    echo "📝 Generating schema for $chart_name..."

    if [ -f "$chart/values.yaml" ]; then
        helm schema-gen "$chart/values.yaml" > "$chart/values.schema.json"
        echo "✅ Schema generated: $chart/values.schema.json"
    else
        echo "⚠️  No values.yaml found for $chart_name"
    fi
done

echo ""
echo "🎉 All schemas generated successfully!"
echo ""
echo "Next steps:"
echo "1. Review the generated schemas in each chart directory"
echo "2. Customize them if needed (add descriptions, constraints, etc.)"
echo "3. Commit and push to trigger a new release"
echo "4. Artifact Hub will automatically display the schema documentation"
