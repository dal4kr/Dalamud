using System;

using Dalamud.Interface.GameFonts;

using Xunit;

namespace Dalamud.Test.Interface.GameFonts
{
    public class GameFontStyleTests
    {
        [Theory]
        [InlineData(12f, "Krnaxis120")]
        [InlineData(14f, "Krnaxis140")]
        [InlineData(18f, "Krnaxis180")]
        [InlineData(18.01f, "Krnaxis360")]
        [InlineData(24f, "Krnaxis360")]
        [InlineData(36f, "Krnaxis360")]
        [InlineData(48f, "Krnaxis360")]
        public void AxisRequestsSelectKoreanFont(float sizePt, string expected)
        {
            Assert.Equal(expected, GameFontStyle.GetRecommendedFamilyAndSize(GameFontFamily.Axis, sizePt).ToString());
        }

        [Fact]
        public void KoreanAxis36HasCorrectFamilyAndSize()
        {
            Assert.True(Enum.TryParse<GameFontFamilyAndSize>("Krnaxis360", out var font));

            var style = new GameFontStyle(font);
            Assert.Equal(GameFontFamily.Axis, style.Family);
            Assert.Equal(36f, style.BaseSizePt);
            Assert.Equal(48f, style.BaseSizePx);
            Assert.Equal(36f, style.SizePt);
            Assert.Equal(GameFontFamilyAndSize.Krnaxis120, style.FamilyWithMinimumSize);
        }

        [Fact]
        public void PixelSizedAndScaledAxisRequestsSelectKorean36()
        {
            var pixelStyle = new GameFontStyle(GameFontFamily.Axis, 48f);
            var scaledStyle = new GameFontStyle(GameFontFamilyAndSize.Krnaxis180).Scale(2f);

            Assert.Equal("Krnaxis360", pixelStyle.FamilyAndSize.ToString());
            Assert.Equal("Krnaxis360", scaledStyle.FamilyAndSize.ToString());
            Assert.Equal(36f, scaledStyle.SizePt);
            Assert.Equal(GameFontFamilyAndSize.Krnaxis180, scaledStyle.Scale(0.5f).FamilyAndSize);
        }

        [Fact]
        public void ExistingFontEnumValuesStayCompatible()
        {
            Assert.Equal(9, (int)GameFontFamilyAndSize.Jupiter16);
            Assert.Equal(26, (int)GameFontFamilyAndSize.TrumpGothic68);
        }
    }
}
