//
//  ProjectSpec.swift
//  Carthage
//
//  Created by Robert Böhnke on 27/12/14.
//  Copyright (c) 2014 Carthage. All rights reserved.
//

@testable import CarthageKit
import Foundation
import Nimble
import Quick
import ReactiveSwift
import Tentacle
import Result
import ReactiveTask
import XCDBLD

class ProjectSpec: QuickSpec {
	override func spec() {
		describe("createAndCheckVersionFiles") {
			let directoryURL = Bundle(for: type(of: self)).url(forResource: "DependencyTest", withExtension: nil)!
			let buildDirectoryURL = directoryURL.appendingPathComponent(CarthageBinariesFolderPath)
			
			func buildDependencyTest(platforms: Set<Platform> = [], cacheBuilds: Bool = true) -> Set<String> {
				var builtSchemes: [String] = []
				
				let project = Project(directoryURL: directoryURL)
				let result = project.buildCheckedOutDependenciesWithOptions(BuildOptions(configuration: "Debug", platforms: platforms, toolchain: "com.apple.dt.toolchain.Swift_2_3", cacheBuilds: cacheBuilds))
					.flatten(.concat)
					.ignoreTaskData()
					.on(value: { (project, scheme) in
						NSLog("Building scheme \"\(scheme)\" in \(project)")
						builtSchemes.append(scheme)
					})
					.wait()
				expect(result.error).to(beNil())
				
				return Set(builtSchemes)
			}
			
			func overwriteFramework(_ frameworkName: String, forPlatformName platformName: String, inDirectory buildDirectoryURL: URL) {
				let platformURL = buildDirectoryURL.appendingPathComponent(platformName, isDirectory: true)
				let frameworkURL = platformURL.appendingPathComponent("\(frameworkName).framework", isDirectory: false)
				let binaryURL = frameworkURL.appendingPathComponent(frameworkName, isDirectory: false)
				
				let data = "junkdata".data(using: .utf8)!
				try! data.write(to: binaryURL, options: .atomic)
			}
			
			beforeEach {
				let _ = try? FileManager.default.removeItem(at: buildDirectoryURL)
			}
			
			it("should not rebuild cached frameworks unless instructed to ignore cached builds") {
				let expected: Set = ["Prelude-Mac", "Either-Mac", "Madness-Mac"]
				
				let result1 = buildDependencyTest(platforms: [.macOS])
				expect(result1).to(equal(expected))
				
				let result2 = buildDependencyTest(platforms: [.macOS])
				expect(result2).to(equal(Set<String>()))
				
				let result3 = buildDependencyTest(platforms: [.macOS], cacheBuilds: false)
				expect(result3).to(equal(expected))
			}
			
			it("should rebuild cached frameworks (and dependencies) whose md5 does not match the version file") {
				let expected: Set = ["Prelude-Mac", "Either-Mac", "Madness-Mac"]
				
				let result1 = buildDependencyTest(platforms: [.macOS])
				expect(result1).to(equal(expected))
				
				overwriteFramework("Prelude", forPlatformName: "Mac", inDirectory: buildDirectoryURL)
				
				let result2 = buildDependencyTest(platforms: [.macOS])
				expect(result2).to(equal(expected))
			}
			
			it("should rebuild cached frameworks (and dependencies) whose version does not match the version file") {
				let expected: Set = ["Prelude-Mac", "Either-Mac", "Madness-Mac"]
				
				let result1 = buildDependencyTest(platforms: [.macOS])
				expect(result1).to(equal(expected))
				
				let preludeVersionFileURL = buildDirectoryURL.appendingPathComponent(".Prelude.version", isDirectory: false)
				let preludeVersionFilePath = preludeVersionFileURL.path
				
				let json = try! String(contentsOf: preludeVersionFileURL, encoding: .utf8)
				let modifiedJson = json.replacingOccurrences(of: "\"commitish\" : \"1.6.0\"", with: "\"commitish\" : \"1.6.1\"")
				let _ = try! modifiedJson.write(toFile: preludeVersionFilePath, atomically: true, encoding: .utf8)
				
				let result2 = buildDependencyTest(platforms: [.macOS])
				expect(result2).to(equal(expected))
			}
			
			it("should not rebuild cached frameworks unnecessarily") {
				let expected: Set = ["Prelude-Mac", "Either-Mac", "Madness-Mac"]
				
				let result1 = buildDependencyTest(platforms: [.macOS])
				expect(result1).to(equal(expected))
				
				overwriteFramework("Either", forPlatformName: "Mac", inDirectory: buildDirectoryURL)
				
				let result2 = buildDependencyTest(platforms: [.macOS])
				expect(result2).to(equal(["Either-Mac", "Madness-Mac"]))
			}
			
			it("should rebuild a framework for all platforms even a cached framework is invalid for only a single platform") {
				let expected: Set = ["Prelude-Mac", "Prelude-iOS", "Either-Mac", "Either-iOS", "Madness-Mac", "Madness-iOS"]
				
				let result1 = buildDependencyTest()
				expect(result1).to(equal(expected))
				
				overwriteFramework("Madness", forPlatformName: "Mac", inDirectory: buildDirectoryURL)
				
				let result2 = buildDependencyTest()
				expect(result2).to(equal(["Madness-Mac", "Madness-iOS"]))
			}
		}
		
		describe("loadCombinedCartfile") {
			it("should load a combined Cartfile when only a Cartfile is present") {
				let directoryURL = Bundle(for: type(of: self)).url(forResource: "CartfileOnly", withExtension: nil)!
				let result = Project(directoryURL: directoryURL).loadCombinedCartfile().single()
				expect(result).notTo(beNil())
				expect(result?.value).notTo(beNil())
				
				let dependencies = result?.value?.dependencies
				expect(dependencies?.count) == 1
				expect(dependencies?.first?.project.name) == "Carthage"
			}

			it("should load a combined Cartfile when only a Cartfile.private is present") {
				let directoryURL = Bundle(for: type(of: self)).url(forResource: "CartfilePrivateOnly", withExtension: nil)!
				let result = Project(directoryURL: directoryURL).loadCombinedCartfile().single()
				expect(result).notTo(beNil())
				expect(result?.value).notTo(beNil())

				let dependencies = result?.value?.dependencies
				expect(dependencies?.count) == 1
				expect(dependencies?.first?.project.name) == "Carthage"
			}

			it("should detect duplicate dependencies across Cartfile and Cartfile.private") {
				let directoryURL = Bundle(for: type(of: self)).url(forResource: "DuplicateDependencies", withExtension: nil)!
				let result = Project(directoryURL: directoryURL).loadCombinedCartfile().single()
				expect(result).notTo(beNil())

				let resultError = result?.error
				expect(resultError).notTo(beNil())

				let makeDependency: (String, String, [String]) -> DuplicateDependency = { (repoOwner, repoName, locations) in
					let project = ProjectIdentifier.gitHub(Repository(owner: repoOwner, name: repoName))
					return DuplicateDependency(project: project, locations: locations)
				}

				let locations = ["\(CarthageProjectCartfilePath)", "\(CarthageProjectPrivateCartfilePath)"]

				let expectedError = CarthageError.duplicateDependencies([
					makeDependency("1", "1", locations),
					makeDependency("3", "3", locations),
					makeDependency("5", "5", locations),
				])

				expect(resultError) == expectedError
			}
			
			it("should error when neither a Cartfile nor a Cartfile.private exists") {
				let directoryURL = Bundle(for: type(of: self)).url(forResource: "NoCartfile", withExtension: nil)!
				let result = Project(directoryURL: directoryURL).loadCombinedCartfile().single()
				expect(result).notTo(beNil())
				
				if case let .readFailed(_, underlyingError)? = result?.error {
					expect(underlyingError?.domain) == NSCocoaErrorDomain
					expect(underlyingError?.code) == NSFileReadNoSuchFileError
				} else {
					fail()
				}
			}
		}

		describe("cloneOrFetchProject") {
			// https://github.com/Carthage/Carthage/issues/1191
			let temporaryPath = (NSTemporaryDirectory() as NSString).appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
			let temporaryURL = URL(fileURLWithPath: temporaryPath, isDirectory: true)
			let repositoryURL = temporaryURL.appendingPathComponent("carthage1191", isDirectory: true)
			let cacheDirectoryURL = temporaryURL.appendingPathComponent("cache", isDirectory: true)
			let projectIdentifier = ProjectIdentifier.git(GitURL(repositoryURL.carthage_absoluteString))

			func initRepository() {
				expect { try FileManager.default.createDirectory(atPath: repositoryURL.carthage_path, withIntermediateDirectories: true) }.notTo(throwError())
				_ = launchGitTask([ "init" ], repositoryFileURL: repositoryURL).wait()
			}

			@discardableResult
			func addCommit() -> String {
				_ = launchGitTask([ "commit", "--allow-empty", "-m \"Empty commit\"" ], repositoryFileURL: repositoryURL).wait()
				return launchGitTask([ "rev-parse", "--short", "HEAD" ], repositoryFileURL: repositoryURL)
					.last()!
					.value!
					.trimmingCharacters(in: .newlines)
			}

			func cloneOrFetch(commitish: String? = nil) -> SignalProducer<(ProjectEvent?, URL), CarthageError> {
				return cloneOrFetchProject(projectIdentifier, preferHTTPS: false, destinationURL: cacheDirectoryURL, commitish: commitish)
			}

			func assertProjectEvent(commitish: String? = nil, clearFetchTime: Bool = true, action: @escaping (ProjectEvent?) -> ()) {
				waitUntil { done in
					if clearFetchTime {
						FetchCache.clearFetchTimes()
					}
					cloneOrFetch(commitish: commitish).start(Observer(
						value: { event, _ in action(event) },
						completed: done
					))
				}
			}

			beforeEach {
				expect { try FileManager.default.createDirectory(atPath: temporaryURL.carthage_path, withIntermediateDirectories: true) }.notTo(throwError())
				initRepository()
			}

			afterEach {
				_ = try? FileManager.default.removeItem(at: temporaryURL)
			}

			it("should clone a project if it is not cloned yet") {
				assertProjectEvent { expect($0?.isCloning) == true }
			}

			it("should fetch a project if no commitish is given") {
				// Clone first
				expect(cloneOrFetch().wait().error).to(beNil())

				assertProjectEvent { expect($0?.isFetching) == true }
			}

			it("should fetch a project if the given commitish does not exist in the cloned repository") {
				// Clone first
				addCommit()
				expect(cloneOrFetch().wait().error).to(beNil())

				let commitish = addCommit()

				assertProjectEvent(commitish: commitish) { expect($0?.isFetching) == true }
			}

			it("should fetch a project if the given commitish exists but that is a reference") {
				// Clone first
				addCommit()
				expect(cloneOrFetch().wait().error).to(beNil())

				addCommit()

				assertProjectEvent(commitish: "master") { expect($0?.isFetching) == true }
			}

			it("should not fetch a project if the given commitish exists but that is not a reference") {
				// Clone first
				let commitish = addCommit()
				expect(cloneOrFetch().wait().error).to(beNil())

				addCommit()

				assertProjectEvent(commitish: commitish) { expect($0).to(beNil()) }
			}

			it ("should not fetch twice in a row, even if no commitish is given") {
				// Clone first
				expect(cloneOrFetch().wait().error).to(beNil())

				assertProjectEvent { expect($0?.isFetching) == true }
				assertProjectEvent(clearFetchTime: false) { expect($0).to(beNil())}
			}
		}
	}
}

private extension ProjectEvent {
	var isCloning: Bool {
		if case .cloning = self {
			return true
		}
		return false
	}

	var isFetching: Bool {
		if case .fetching = self {
			return true
		}
		return false
	}
}
