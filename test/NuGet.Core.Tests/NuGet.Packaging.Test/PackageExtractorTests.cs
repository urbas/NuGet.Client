using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using NuGet.Test.Utility;
using Xunit;

namespace NuGet.Packaging.Test
{
    public class PackageExtractorTests
    {
        [Fact]
        public async Task PackageExtractor_withContentXmlFile()
        {
            // Arrange
            using (var packageStream = TestPackages.GetTestPackageWithContentXmlFile())
            {
                var root = TestFileSystemUtility.CreateRandomTestFolder();
                var packageReader = new PackageReader(packageStream);
                var packagePath = Path.Combine(root, "packageA.2.0.3");

                // Act
                var files = await PackageExtractor.ExtractPackageAsync(packageReader,
                                                                 packageStream,
                                                                 new PackagePathResolver(root),
                                                                 packageExtractionContext: null,
                                                                 token: CancellationToken.None);

                // Assert
                Assert.False(files.Contains(Path.Combine(packagePath + "[Content_Types].xml")));
                Assert.True(files.Contains(Path.Combine(packagePath, "content/[Content_Types].xml")));

                // Clean
                TestFileSystemUtility.DeleteRandomTestFolders(root);
            }
        }

        [Fact]
        public async Task PackageExtractor_duplicateNupkg()
        {
            // Arrange
            var packageNupkg = TestPackages.GetLegacyTestPackage();
            var root = TestFileSystemUtility.CreateRandomTestFolder();
            var zip = new ZipArchive(packageNupkg.OpenRead());
            var zipReader = new PackageReader(zip);

            var folder = Path.Combine(packageNupkg.Directory.FullName, Guid.NewGuid().ToString());

            using (var zipFile = new ZipArchive(File.OpenRead(packageNupkg.FullName)))
            {
                zipFile.ExtractAll(folder);

                var folderReader = new PackageFolderReader(folder);

                // Act
                var files = await PackageExtractor.ExtractPackageAsync(folderReader,
                                                                 File.OpenRead(packageNupkg.FullName),
                                                                 new PackagePathResolver(root),
                                                                 packageExtractionContext: null,
                                                                 token: CancellationToken.None);

                // Assert
                Assert.Equal(1, files.Where(p => p.EndsWith(".nupkg")).Count());

                // Clean
                TestFileSystemUtility.DeleteRandomTestFolders(root, folder);
            }
        }

        [Fact]
        public async Task PackageExtractor_PackageSaveModeNupkg_FolderReader()
        {
            // Arrange
            var packageNupkg = TestPackages.GetLegacyTestPackage();
            var root = TestFileSystemUtility.CreateRandomTestFolder();
            var zip = new ZipArchive(packageNupkg.OpenRead());
            var zipReader = new PackageReader(zip);
            var packageExtractionContext = new PackageExtractionContext();
            packageExtractionContext.PackageSaveMode = PackageSaveModes.Nupkg;

            var folder = Path.Combine(packageNupkg.Directory.FullName, Guid.NewGuid().ToString());

            using (var zipFile = new ZipArchive(File.OpenRead(packageNupkg.FullName)))
            {
                zipFile.ExtractAll(folder);

                var folderReader = new PackageFolderReader(folder);

                // Act
                var files = await PackageExtractor.ExtractPackageAsync(folderReader,
                                                                 File.OpenRead(packageNupkg.FullName),
                                                                 new PackagePathResolver(root),
                                                                 packageExtractionContext,
                                                                 CancellationToken.None);

                // Assert
                Assert.True(files.Any(p => p.EndsWith(".nupkg")));
                Assert.False(files.Any(p => p.EndsWith(".nuspec")));

                // Clean
                TestFileSystemUtility.DeleteRandomTestFolders(root, folder);
            }
        }

        [Fact]
        public async Task PackageExtractor_PackageSaveModeNuspec_FolderReader()
        {
            // Arrange
            var packageNupkg = TestPackages.GetLegacyTestPackage();
            var root = TestFileSystemUtility.CreateRandomTestFolder();
            var zip = new ZipArchive(packageNupkg.OpenRead());
            var zipReader = new PackageReader(zip);
            var packageExtractionContext = new PackageExtractionContext();
            packageExtractionContext.PackageSaveMode = PackageSaveModes.Nuspec;

            var folder = Path.Combine(packageNupkg.Directory.FullName, Guid.NewGuid().ToString());

            using (var zipFile = new ZipArchive(File.OpenRead(packageNupkg.FullName)))
            {
                zipFile.ExtractAll(folder);

                var folderReader = new PackageFolderReader(folder);

                // Act
                var files = await PackageExtractor.ExtractPackageAsync(folderReader,
                                                                 File.OpenRead(packageNupkg.FullName),
                                                                 new PackagePathResolver(root),
                                                                 packageExtractionContext,
                                                                 CancellationToken.None);

                // Assert
                Assert.False(files.Any(p => p.EndsWith(".nupkg")));
                Assert.True(files.Any(p => p.EndsWith(".nuspec")));

                // Clean
                TestFileSystemUtility.DeleteRandomTestFolders(root, folder);
            }
        }

        [Fact]
        public async Task PackageExtractor_PackageSaveModeNuspecAndNupkg_PackageStream()
        {
            // Arrange
            using (var packageStream = TestPackages.GetTestPackageWithContentXmlFile())
            {
                var root = TestFileSystemUtility.CreateRandomTestFolder();
                var packageReader = new PackageReader(packageStream);
                var packagePath = Path.Combine(root, "packageA.2.0.3");
                var packageExtractionContext = new PackageExtractionContext();
                packageExtractionContext.PackageSaveMode = PackageSaveModes.Nuspec | PackageSaveModes.Nupkg;

                // Act
                var files = await PackageExtractor.ExtractPackageAsync(packageReader,
                                                                 packageStream,
                                                                 new PackagePathResolver(root),
                                                                 packageExtractionContext,
                                                                 CancellationToken.None);

                // Assert
                Assert.True(files.Any(p => p.EndsWith(".nupkg")));
                Assert.True(files.Any(p => p.EndsWith(".nuspec")));

                // Clean
                TestFileSystemUtility.DeleteRandomTestFolders(root);
            }
        }

        [Fact]
        public async Task PackageExtractor_DefaultPackageExtractionContext()
        {
            // Arrange
            var root = TestFileSystemUtility.CreateRandomTestFolder();
            var packageFileInfo = TestPackages.GetRuntimePackage(root, "A", "2.0.3");
            var satellitePackageInfo = TestPackages.GetSatellitePackage(root, "A", "2.0.3");

            using (var packageStream = File.OpenRead(packageFileInfo.FullName))
                using (var satellitePackageStream = File.OpenRead(satellitePackageInfo.FullName))
            {
                // Act
                var packageFiles = await PackageExtractor.ExtractPackageAsync(packageStream,
                                                                 new PackagePathResolver(root),
                                                                 packageExtractionContext: null,
                                                                 token: CancellationToken.None);

                var satellitePackageFiles = await PackageExtractor.ExtractPackageAsync(satellitePackageStream,
                                                                 new PackagePathResolver(root),
                                                                 packageExtractionContext: null,
                                                                 token: CancellationToken.None);

                var pathToAFrDllInSatellitePackage = Path.Combine(root, "A.fr.2.0.3", "lib", "net45", "A.fr.dll");
                var pathToAFrDllInRunTimePackage = Path.Combine(root, "A.2.0.3", "lib", "net45", "fr", "A.fr.dll");

                Assert.True(File.Exists(pathToAFrDllInSatellitePackage));
                Assert.True(File.Exists(pathToAFrDllInRunTimePackage));
            }
        }
    }
}
