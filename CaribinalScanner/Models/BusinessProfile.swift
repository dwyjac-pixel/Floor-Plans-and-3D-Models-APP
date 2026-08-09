import SwiftUI
import UIKit
import PhotosUI

/// The business identity printed on every estimate and report — the
/// foundation for commercialization, where each subscriber (business or
/// individual) brands their own documents.
struct BusinessProfile: Codable {
    var businessName = "Caribinal Creations Ltd."
    var contactName = ""
    var phone = ""
    var email = ""
    var address = ""
    var gstNumber = ""
    var slogan = ""
    var bannerHex = "default"

    static let storageKey = "businessProfile"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case businessName, contactName, phone, email, address, gstNumber, slogan, bannerHex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        businessName = try container.decodeIfPresent(String.self, forKey: .businessName) ?? "Caribinal Creations Ltd."
        contactName = try container.decodeIfPresent(String.self, forKey: .contactName) ?? ""
        phone = try container.decodeIfPresent(String.self, forKey: .phone) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        gstNumber = try container.decodeIfPresent(String.self, forKey: .gstNumber) ?? ""
        slogan = try container.decodeIfPresent(String.self, forKey: .slogan) ?? ""
        bannerHex = try container.decodeIfPresent(String.self, forKey: .bannerHex) ?? "default"
    }

    static func load() -> BusinessProfile {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let profile = try? JSONDecoder().decode(BusinessProfile.self, from: data) else {
            return BusinessProfile()
        }
        return profile
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Logo

    static var logoURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("business_logo.png")
    }

    static func loadLogo() -> UIImage? {
        UIImage(contentsOfFile: logoURL.path)
    }

    static func saveLogo(_ image: UIImage?) {
        if let image, let data = image.pngData() {
            try? data.write(to: logoURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: logoURL)
        }
    }
}

struct BusinessProfileScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile = BusinessProfile.load()
    @State private var logo: UIImage? = BusinessProfile.loadLogo()
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        if let logo {
                            Image(uiImage: logo)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel("Business logo")
                        } else {
                            Image(systemName: "building.2.crop.circle")
                                .font(.system(size: 44))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            PhotosPicker(logo == nil ? "Add Logo" : "Change Logo",
                                         selection: $pickerItem, matching: .images)
                            if logo != nil {
                                Button("Remove Logo", role: .destructive) {
                                    logo = nil
                                    BusinessProfile.saveLogo(nil)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Logo")
                } footer: {
                    Text("Appears on the cover of every report and estimate.")
                }

                Section("Business") {
                    TextField("Business name", text: $profile.businessName)
                    TextField("Slogan / tagline", text: $profile.slogan)
                    TextField("Contact name", text: $profile.contactName)
                    TextField("Address", text: $profile.address)
                    TextField("Phone", text: $profile.phone)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $profile.email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    ColorPicker("Banner colour", selection: Binding(
                        get: { Color(hexString: profile.bannerHex) ?? Color(red: 0.55, green: 0.13, blue: 0.18) },
                        set: { profile.bannerHex = $0.hexString() }
                    ), supportsOpacity: false)
                    Button("Reset Banner Colour") { profile.bannerHex = "default" }
                } header: {
                    Text("Branding")
                } footer: {
                    Text("The banner colour and slogan appear on the report cover and page headers. Keep the colour dark enough for white text to read.")
                }

                Section {
                    TextField("GST / HST number", text: $profile.gstNumber)
                        .textInputAutocapitalization(.characters)
                } header: {
                    Text("Tax")
                } footer: {
                    Text("Your business name and GST number print on every estimate and report the app generates.")
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .navigationTitle("Business Profile")
            .keyboardDoneButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        profile.save()
                        dismiss()
                    }
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        logo = image
                        BusinessProfile.saveLogo(image)
                    }
                    pickerItem = nil
                }
            }
            // The logo commits immediately on pick/remove; persist the text
            // fields on swipe-down too, so a Back/swipe doesn't discard them
            // (QA-049).
            .onDisappear {
                profile.save()
            }
        }
    }
}
